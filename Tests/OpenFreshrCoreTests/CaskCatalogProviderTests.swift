import Foundation
import Testing
@testable import OpenFreshrCore

/// Coverage for the live catalog refresh: the strict **network → cache →
/// snapshot** order, the conditional `304` fast path, the "a failure never loses
/// data" rule, and — the load-bearing safety property — that the cache is only
/// ever re-ingested through the Homebrew **API form**, so a tampered cache file
/// cannot inject internal identity fields.
struct CaskCatalogProviderTests {

    // Distinct in-test URLs so the fake fetcher can key on them without any real
    // network endpoint being involved.
    private let caskURL = URL(string: "https://example.test/cask.json")!
    private let analyticsURL = URL(string: "https://example.test/analytics.json")!

    // MARK: - Fixtures

    /// Raw bytes of a `cask.json` array from a list of raw cask dictionaries.
    private func caskAPIData(_ casks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: casks)
    }

    /// A one-cask API document whose `uninstall.quit` gives it a *strong* identity,
    /// so a correct ingestion is observable via `primaryBundleIdentifiers`.
    private func caskWithStrongIdentity(token: String, helper: String) throws -> Data {
        try caskAPIData([[
            "token": token,
            "version": "1.0",
            "artifacts": [
                ["app": ["\(token).app"], "target": "\(token).app"],
                ["uninstall": [["quit": helper]]],
            ],
        ]])
    }

    /// The bundled-snapshot stand-in: a single, recognisably "snapshot" cask.
    private func snapshotCatalog(fetchedAt: Date) -> CaskCatalog {
        let cask = Cask(
            token: "snapshot-app",
            names: ["Snapshot App"],
            oldTokens: [],
            version: "9.9",
            autoUpdates: false,
            homepage: nil,
            artifacts: [CaskArtifact(kind: .app, target: "Snapshot App.app")],
            primaryBundleIdentifiers: [],
            cleanupBundleIdentifiers: []
        )
        return CaskCatalog(casks: [cask], fetchedAt: fetchedAt)
    }

    private func makeProvider(
        fetcher: FakeHTTPFetcher,
        store: FakeCatalogCacheStore,
        snapshotDate: Date = Date(timeIntervalSince1970: 1_000)
    ) -> CaskCatalogProvider {
        CaskCatalogProvider(
            httpFetcher: fetcher,
            cacheStore: store,
            caskURL: caskURL,
            analyticsURL: analyticsURL,
            bundledSnapshot: { self.snapshotCatalog(fetchedAt: snapshotDate) }
        )
    }

    // MARK: - 1. Fresh fetch replaces the cache and is ingested

    @Test
    func freshFetchReplacesCacheAndIsIngested() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fetcher = FakeHTTPFetcher()
        let store = FakeCatalogCacheStore()

        let fresh = try caskWithStrongIdentity(token: "fresh-app", helper: "com.fresh.helper")
        fetcher.setConditionalModified(fresh, validators: CatalogValidators(etag: "v-fresh"), for: caskURL.absoluteString)
        // Analytics arrives alongside and should be cached too.
        let analytics = Data(#"{"items":[{"cask":"fresh-app","count":"1,234"}]}"#.utf8)
        fetcher.setConditionalModified(analytics, validators: CatalogValidators(etag: "a1"), for: analyticsURL.absoluteString)

        let provider = makeProvider(fetcher: fetcher, store: store)
        let load = await provider.refresh(now: now)

        #expect(load.origin == .network)
        #expect(load.error == nil)
        let cask = try #require(load.catalog.casks.first { $0.token == "fresh-app" })
        // Ingestion actually ran: the strong identity was recovered.
        #expect(cask.primaryBundleIdentifiers == ["com.fresh.helper"])
        // The cache now holds the fresh bytes, validators and dates.
        let cached = try #require(store.current)
        #expect(cached.caskAPIData == fresh)
        #expect(cached.caskValidators.etag == "v-fresh")
        #expect(cached.fetchedAt == now)
        #expect(cached.checkedAt == now)
        #expect(load.checkedAt == now)
        // Analytics rode along and is exposed for phase-5 ranking.
        #expect(load.analytics?.installs(for: "fresh-app") == 1_234)
        #expect(cached.analyticsAPIData == analytics)
    }

    // MARK: - 2. 304 Not Modified keeps the cache, advances only checkedAt

    @Test
    func notModifiedKeepsCacheAndAdvancesOnlyCheckedAt() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)          // fetched
        let t1 = t0.addingTimeInterval(48 * 3_600)               // checked, 48h later
        let fetcher = FakeHTTPFetcher()

        let cachedData = try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper")
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: cachedData,
            analyticsAPIData: nil,
            caskValidators: CatalogValidators(etag: "v1"),
            analyticsValidators: CatalogValidators(),
            fetchedAt: t0,
            checkedAt: t0
        ))
        fetcher.setConditionalNotModified(for: caskURL.absoluteString)

        let provider = makeProvider(fetcher: fetcher, store: store)
        let load = await provider.refresh(now: t1)

        #expect(load.origin == .cache)
        #expect(load.error == nil)
        #expect(load.catalog.casks.map(\.token) == ["cached-app"])
        // Age is measured from the *fetch*, which did not move: still 48h.
        #expect(load.catalog.fetchedAt == t0)
        #expect(load.catalog.age(now: t1) == 48 * 3_600)
        #expect(load.checkedAt == t1)
        // Persisted cache: fetchedAt pinned, checkedAt advanced.
        let cached = try #require(store.current)
        #expect(cached.fetchedAt == t0)
        #expect(cached.checkedAt == t1)
        // The conditional request replayed the stored validator.
        #expect(fetcher.conditionalRequests.first?.validators.etag == "v1")
    }

    // MARK: - 3. Network error keeps the prior catalog and reports the failure

    @Test
    func networkErrorKeepsPriorCatalogAndReportsError() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = t0.addingTimeInterval(3_600)
        let fetcher = FakeHTTPFetcher()

        let cachedData = try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper")
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: cachedData,
            caskValidators: CatalogValidators(etag: "v1"),
            fetchedAt: t0,
            checkedAt: t0
        ))
        fetcher.setConditionalFailure("offline", for: caskURL.absoluteString)

        let provider = makeProvider(fetcher: fetcher, store: store)
        let load = await provider.refresh(now: t1)

        #expect(load.error?.kind == .network)
        #expect(load.origin == .cache)
        #expect(load.catalog.casks.map(\.token) == ["cached-app"])
        // Nothing was lost and nothing was rewritten.
        #expect(store.saveCount == 0)
        let cached = try #require(store.current)
        #expect(cached.fetchedAt == t0)
        #expect(cached.checkedAt == t0)
    }

    @Test
    func networkErrorWithoutPriorCacheFallsBackToSnapshot() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fetcher = FakeHTTPFetcher()
        let store = FakeCatalogCacheStore()
        fetcher.setConditionalFailure("offline", for: caskURL.absoluteString)

        let provider = makeProvider(fetcher: fetcher, store: store)
        let load = await provider.refresh(now: now)

        #expect(load.error?.kind == .network)
        #expect(load.origin == .bundledSnapshot)
        #expect(load.catalog.casks.map(\.token) == ["snapshot-app"])
    }

    // MARK: - 4. A corrupt cache falls back to the bundled snapshot

    @Test
    func corruptCacheFallsBackToSnapshotOnInitialLoad() {
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: Data("this is not a cask.json array".utf8),
            fetchedAt: Date(timeIntervalSince1970: 500),
            checkedAt: Date(timeIntervalSince1970: 500)
        ))
        let provider = makeProvider(fetcher: FakeHTTPFetcher(), store: store)

        let load = provider.loadInitial()

        #expect(load.origin == .bundledSnapshot)
        #expect(load.catalog.casks.map(\.token) == ["snapshot-app"])
        #expect(load.error == nil)
    }

    @Test
    func validCacheIsPreferredOnInitialLoad() throws {
        let t0 = Date(timeIntervalSince1970: 1_500_000)
        let cachedData = try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper")
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: cachedData,
            fetchedAt: t0,
            checkedAt: t0
        ))
        let provider = makeProvider(fetcher: FakeHTTPFetcher(), store: store)

        let load = provider.loadInitial()

        #expect(load.origin == .cache)
        #expect(load.catalog.casks.map(\.token) == ["cached-app"])
    }

    // MARK: - 5. The cache is read via the API form — injected fields have no effect

    @Test
    func cacheIsReadThroughAPIFormSoInjectedIdentityIsIgnored() throws {
        // A hostile cache file: a *valid* API array, but each cask also carries a
        // top-level `primaryBundleIdentifiers`/`cleanupBundleIdentifiers` as if it
        // could set the internal safety fields directly. Ingestion never reads
        // those; it recomputes the buckets from the stanzas. The injected primary
        // id must vanish, and only the *path*-derived id must appear in cleanup.
        let hostile = try caskAPIData([[
            "token": "victim",
            "version": "1.0",
            "primaryBundleIdentifiers": ["com.attacker.injected"],
            "cleanupBundleIdentifiers": ["com.attacker.injected"],
            "auto_updates": false,
            "artifacts": [
                ["app": ["Victim.app"], "target": "Victim.app"],
                ["zap": [["trash": "~/Library/Containers/com.real.debris"]]],
            ],
        ]])
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: hostile,
            fetchedAt: Date(timeIntervalSince1970: 10),
            checkedAt: Date(timeIntervalSince1970: 10)
        ))
        let provider = makeProvider(fetcher: FakeHTTPFetcher(), store: store)

        let load = provider.loadInitial()
        #expect(load.origin == .cache)
        let cask = try #require(load.catalog.casks.first { $0.token == "victim" })

        // The decisive assertions: the injected strong identity had NO effect.
        #expect(cask.primaryBundleIdentifiers == [])
        #expect(!cask.primaryBundleIdentifiers.contains("com.attacker.injected"))
        // Only the id recovered from the real cleanup *path* survives.
        #expect(cask.cleanupBundleIdentifiers == ["com.real.debris"])
    }

    // MARK: - 6. Cache age is computed and reported

    @Test
    func cacheAgeIsComputedFromFetchDate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fetchedAt = now.addingTimeInterval(-3_600)   // one hour old
        let checkedAt = now.addingTimeInterval(-60)       // checked a minute ago
        let cachedData = try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper")
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: cachedData,
            caskValidators: CatalogValidators(etag: "v1"),
            fetchedAt: fetchedAt,
            checkedAt: checkedAt
        ))
        let provider = makeProvider(fetcher: FakeHTTPFetcher(), store: store)

        let load = provider.loadInitial()

        #expect(load.catalog.age(now: now) == 3_600)
        #expect(load.checkedAt == checkedAt)
    }

    // MARK: - Robustness: fresh bytes that will not ingest keep prior data

    @Test
    func unparsableFreshBytesKeepPriorCatalogAsIngestionError() async throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = t0.addingTimeInterval(3_600)
        let fetcher = FakeHTTPFetcher()
        let cachedData = try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper")
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: cachedData,
            caskValidators: CatalogValidators(etag: "v1"),
            fetchedAt: t0,
            checkedAt: t0
        ))
        // Server says "modified" but the body is not a cask.json array.
        fetcher.setConditionalModified(Data("{}".utf8), validators: CatalogValidators(etag: "v2"), for: caskURL.absoluteString)

        let provider = makeProvider(fetcher: fetcher, store: store)
        let load = await provider.refresh(now: t1)

        #expect(load.error?.kind == .ingestion)
        #expect(load.origin == .cache)
        #expect(load.catalog.casks.map(\.token) == ["cached-app"])
        // The bad payload was not written over the good cache.
        #expect(store.saveCount == 0)
        #expect(store.current?.caskValidators.etag == "v1")
    }

    // MARK: - clearCache

    @Test
    func clearCacheEmptiesTheStore() throws {
        let store = FakeCatalogCacheStore(initial: CachedCatalog(
            caskAPIData: try caskWithStrongIdentity(token: "cached-app", helper: "com.cached.helper"),
            fetchedAt: Date(timeIntervalSince1970: 10),
            checkedAt: Date(timeIntervalSince1970: 10)
        ))
        let provider = makeProvider(fetcher: FakeHTTPFetcher(), store: store)

        try provider.clearCache()

        #expect(store.current == nil)
        #expect(store.clearCount == 1)
    }
}
