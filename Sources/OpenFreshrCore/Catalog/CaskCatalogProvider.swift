import Foundation

/// Where the catalog currently in hand came from, most to least fresh.
public enum CaskCatalogOrigin: Sendable, Equatable {
    /// Downloaded fresh from the Homebrew API this session.
    case network
    /// Re-ingested from the on-disk cache (itself last filled by the network).
    case cache
    /// The snapshot shipped inside the app bundle — the offline/first-run floor.
    case bundledSnapshot
    /// Nothing was available at all (no cache, no snapshot).
    case empty
}

/// A catalog together with its provenance and the outcome of the last attempt.
///
/// The catalog is always present and usable; ``error`` is *additive* — it records
/// that a refresh could not improve on what is here, never that the data was
/// lost. This is the shape of the binding rule "a failed fetch keeps the
/// last-known catalog and only degrades freshness".
public struct CaskCatalogLoad: Sendable {

    /// The catalog to classify against — never empty of meaning, only ever the
    /// best available source.
    public var catalog: CaskCatalog
    /// Where ``catalog`` came from.
    public var origin: CaskCatalogOrigin
    /// The install-popularity table, when the source carried one (network/cache).
    /// `nil` for the bundled snapshot, which ships no analytics.
    public var analytics: CaskInstallAnalytics?
    /// When the server was last *checked*. Differs from ``CaskCatalog/fetchedAt``
    /// after a `304`: the data is old but was just re-validated.
    public var checkedAt: Date
    /// A refresh failure that left prior data in place, if one occurred.
    public var error: CatalogRefreshError?

    public init(
        catalog: CaskCatalog,
        origin: CaskCatalogOrigin,
        analytics: CaskInstallAnalytics? = nil,
        checkedAt: Date,
        error: CatalogRefreshError? = nil
    ) {
        self.catalog = catalog
        self.origin = origin
        self.analytics = analytics
        self.checkedAt = checkedAt
        self.error = error
    }
}

/// Why a refresh did not produce fresher data. Carried on ``CaskCatalogLoad`` so
/// the UI can say *why* the catalog is stale without the fetch ever throwing out
/// of the provider.
public struct CatalogRefreshError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The request failed at the transport/HTTP layer.
        case network
        /// Bytes arrived but could not be ingested; the prior catalog was kept.
        case ingestion
    }
    public var kind: Kind
    /// A short, non-localised description of the underlying failure, for logs and
    /// as a fallback detail in the UI.
    public var detail: String?

    public init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// Loads the cask catalog with a strict freshness order — **network → cache →
/// bundled snapshot** — and keeps the cache safe by construction.
///
/// The single most important property: **cached bytes re-enter through
/// ``CaskCatalogIngestion`` (the Homebrew API form), never through the internal
/// ``Cask`` `Codable` form.** A cache file is as untrusted as the network, so it
/// is run through exactly the same identity-recovery ingestion as a live fetch;
/// a hand-crafted file therefore cannot set ``Cask/primaryBundleIdentifiers``,
/// ``Cask/autoUpdates`` or ``Cask/artifacts`` directly. This is the lesson that
/// retired the earlier `casks.json` cache, encoded as an invariant.
///
/// Two operations, split by whether they touch the network:
///
/// * ``loadInitial()`` is synchronous and offline: cache → snapshot. It is what
///   the first frame classifies against.
/// * ``refresh(now:)`` does the conditional network fetch and returns the best
///   catalog it can, *keeping* prior data on any failure.
public struct CaskCatalogProvider: Sendable {

    public static let defaultCaskURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    public static let defaultAnalyticsURL =
        URL(string: "https://formulae.brew.sh/api/analytics/cask-install/365d.json")!

    private let httpFetcher: any HTTPFetching
    private let cacheStore: any CatalogCacheStoring
    private let caskURL: URL
    private let analyticsURL: URL
    /// Supplies the bundled snapshot. A closure because Core cannot read
    /// `Bundle.main`; the app injects the resource load.
    private let bundledSnapshot: @Sendable () -> CaskCatalog?

    public init(
        httpFetcher: any HTTPFetching,
        cacheStore: any CatalogCacheStoring,
        caskURL: URL = CaskCatalogProvider.defaultCaskURL,
        analyticsURL: URL = CaskCatalogProvider.defaultAnalyticsURL,
        bundledSnapshot: @escaping @Sendable () -> CaskCatalog?
    ) {
        self.httpFetcher = httpFetcher
        self.cacheStore = cacheStore
        self.caskURL = caskURL
        self.analyticsURL = analyticsURL
        self.bundledSnapshot = bundledSnapshot
    }

    // MARK: - Offline load

    /// The best catalog available **without touching the network**: a valid cache
    /// if present and ingestible, otherwise the bundled snapshot, otherwise empty.
    ///
    /// A cache that cannot be ingested (corrupt bytes, or a tampered file whose
    /// injected fields ingestion simply ignores and which then fails to parse as
    /// the API array) degrades to the snapshot — it never crashes and never yields
    /// half-trusted data.
    public func loadInitial() -> CaskCatalogLoad {
        if let cached = cacheStore.load(),
            let catalog = try? ingest(cached.caskAPIData, fetchedAt: cached.fetchedAt)
        {
            return CaskCatalogLoad(
                catalog: catalog,
                origin: .cache,
                analytics: cached.analyticsAPIData.map(CaskInstallAnalytics.parse(fromAPIData:)),
                checkedAt: cached.checkedAt,
                error: nil
            )
        }
        return snapshotLoad()
    }

    // MARK: - Network refresh

    /// Conditionally refresh the catalog and persist the result.
    ///
    /// Outcomes:
    /// * **fresh bytes** → ingested, cached with `fetchedAt = checkedAt = now`,
    ///   origin `.network`;
    /// * **`304 Not Modified`** → cache kept, only `checkedAt` advances, origin
    ///   `.cache` (age keeps growing honestly);
    /// * **ingestion failure** on fresh bytes → prior data kept, origin unchanged,
    ///   `.ingestion` error;
    /// * **transport/HTTP failure** → prior data kept, `.network` error.
    ///
    /// Analytics is refreshed best-effort alongside and never determines success.
    public func refresh(now: Date = Date()) async -> CaskCatalogLoad {
        let prior = cacheStore.load()

        let response: ConditionalResponse
        do {
            response = try await httpFetcher.conditionalGet(
                ConditionalRequest(url: caskURL, validators: prior?.caskValidators ?? CatalogValidators())
            )
        } catch {
            // Transport/HTTP failure: keep whatever we already had.
            return fallback(after: prior, error: CatalogRefreshError(kind: .network, detail: "\(error)"))
        }

        switch response {
        case .notModified:
            return await handleNotModified(prior: prior, now: now)
        case let .modified(data, validators):
            return await handleModified(data: data, validators: validators, prior: prior, now: now)
        }
    }

    /// Erase the on-disk cache (manual invalidation). The in-memory catalog the app
    /// already holds is untouched; the next ``refresh(now:)`` simply starts cold.
    public func clearCache() throws {
        try cacheStore.clear()
    }

    // MARK: - Refresh outcomes

    private func handleModified(
        data: Data,
        validators: CatalogValidators,
        prior: CachedCatalog?,
        now: Date
    ) async -> CaskCatalogLoad {
        let catalog: CaskCatalog
        do {
            catalog = try ingest(data, fetchedAt: now)
        } catch {
            // We fetched, but the payload would not ingest — keep prior data rather
            // than replace a good catalog with an unusable one.
            return fallback(after: prior, error: CatalogRefreshError(kind: .ingestion, detail: "\(error)"))
        }

        let analyticsFetch = await fetchAnalytics(prior: prior)
        let cached = CachedCatalog(
            caskAPIData: data,
            analyticsAPIData: analyticsFetch.data,
            caskValidators: validators,
            analyticsValidators: analyticsFetch.validators,
            fetchedAt: now,
            checkedAt: now
        )
        try? cacheStore.save(cached)

        return CaskCatalogLoad(
            catalog: catalog,
            origin: .network,
            analytics: analyticsFetch.data.map(CaskInstallAnalytics.parse(fromAPIData:)),
            checkedAt: now,
            error: nil
        )
    }

    private func handleNotModified(prior: CachedCatalog?, now: Date) async -> CaskCatalogLoad {
        // A 304 only makes sense against a prior cache; if somehow there is none,
        // there is nothing to keep — fall back to the snapshot.
        guard let prior, let catalog = try? ingest(prior.caskAPIData, fetchedAt: prior.fetchedAt) else {
            return snapshotLoad()
        }

        let analyticsFetch = await fetchAnalytics(prior: prior)
        // Keep the cask payload and its fetch date; advance only the check date and
        // fold in any fresher analytics.
        let refreshed = CachedCatalog(
            caskAPIData: prior.caskAPIData,
            analyticsAPIData: analyticsFetch.data,
            caskValidators: prior.caskValidators,
            analyticsValidators: analyticsFetch.validators,
            fetchedAt: prior.fetchedAt,
            checkedAt: now
        )
        try? cacheStore.save(refreshed)

        return CaskCatalogLoad(
            catalog: catalog,
            origin: .cache,
            analytics: analyticsFetch.data.map(CaskInstallAnalytics.parse(fromAPIData:)),
            checkedAt: now,
            error: nil
        )
    }

    // MARK: - Analytics (best-effort, never load-critical)

    /// Conditionally refresh the analytics document. Any failure — transport error
    /// or unparsable body — keeps the prior analytics; a missing prior just yields
    /// `nil`. Analytics never blocks or fails a catalog refresh.
    private func fetchAnalytics(prior: CachedCatalog?) async -> (data: Data?, validators: CatalogValidators) {
        let priorValidators = prior?.analyticsValidators ?? CatalogValidators()
        do {
            switch try await httpFetcher.conditionalGet(
                ConditionalRequest(url: analyticsURL, validators: priorValidators)
            ) {
            case .notModified:
                return (prior?.analyticsAPIData, priorValidators)
            case let .modified(data, validators):
                return (data, validators)
            }
        } catch {
            return (prior?.analyticsAPIData, priorValidators)
        }
    }

    // MARK: - Fallbacks

    /// Build a load from whatever we still have after a failed refresh: the prior
    /// cache if it ingests, else the snapshot. The `error` rides along so the UI
    /// can explain the staleness without any data being dropped.
    private func fallback(after prior: CachedCatalog?, error: CatalogRefreshError) -> CaskCatalogLoad {
        if let prior, let catalog = try? ingest(prior.caskAPIData, fetchedAt: prior.fetchedAt) {
            return CaskCatalogLoad(
                catalog: catalog,
                origin: .cache,
                analytics: prior.analyticsAPIData.map(CaskInstallAnalytics.parse(fromAPIData:)),
                checkedAt: prior.checkedAt,
                error: error
            )
        }
        var load = snapshotLoad()
        load.error = error
        return load
    }

    private func snapshotLoad() -> CaskCatalogLoad {
        if let snapshot = bundledSnapshot() {
            return CaskCatalogLoad(
                catalog: snapshot,
                origin: .bundledSnapshot,
                analytics: nil,
                checkedAt: snapshot.fetchedAt,
                error: nil
            )
        }
        let empty = CaskCatalog(casks: [], fetchedAt: .distantPast)
        return CaskCatalogLoad(catalog: empty, origin: .empty, analytics: nil, checkedAt: .distantPast, error: nil)
    }

    private func ingest(_ data: Data, fetchedAt: Date) throws -> CaskCatalog {
        try CaskCatalogIngestion.decodeCatalog(fromAPIData: data, fetchedAt: fetchedAt)
    }
}
