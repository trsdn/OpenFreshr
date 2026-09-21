import Foundation

/// The persisted catalog cache: the **raw** Homebrew API bytes plus the metadata
/// a conditional refresh needs.
///
/// Two dates are kept apart on purpose:
///
/// * ``fetchedAt`` — when the catalog *bytes* were last downloaded fresh. This is
///   what the "catalog is N old" hint reports, and it does **not** move on a
///   `304`.
/// * ``checkedAt`` — when the server was last asked. A `304` only moves this,
///   recording that the (unchanged) data was re-validated just now.
///
/// - Important: ``caskAPIData`` is the *unmodified* `cask.json` array, exactly as
///   downloaded. It is re-ingested through ``CaskCatalogIngestion`` (the API
///   form) on every read — it is **never** decoded into the internal ``Cask``
///   `Codable` form. That is the whole safety point of a cache existing at all:
///   a hand-crafted file cannot set ``Cask/primaryBundleIdentifiers`` or
///   ``Cask/autoUpdates`` directly, because those fields are *recovered* by
///   ingestion under our own rules and never read from the bytes verbatim.
public struct CachedCatalog: Sendable, Equatable {

    /// The raw `cask.json` array bytes (Homebrew API shape).
    public var caskAPIData: Data
    /// The raw `analytics/cask-install/365d.json` bytes, when cached.
    public var analyticsAPIData: Data?

    /// The cask document's stored `ETag` / `Last-Modified` validators.
    public var caskValidators: CatalogValidators
    /// The analytics document's stored validators.
    public var analyticsValidators: CatalogValidators

    /// When the cask bytes were last fetched fresh (age is measured from here).
    public var fetchedAt: Date
    /// When the server was last asked (a `304` moves only this).
    public var checkedAt: Date

    public init(
        caskAPIData: Data,
        analyticsAPIData: Data? = nil,
        caskValidators: CatalogValidators = CatalogValidators(),
        analyticsValidators: CatalogValidators = CatalogValidators(),
        fetchedAt: Date,
        checkedAt: Date
    ) {
        self.caskAPIData = caskAPIData
        self.analyticsAPIData = analyticsAPIData
        self.caskValidators = caskValidators
        self.analyticsValidators = analyticsValidators
        self.fetchedAt = fetchedAt
        self.checkedAt = checkedAt
    }
}

/// The persistence boundary for the catalog cache.
///
/// Behind a protocol so the refresh flow is exercised entirely in memory — no
/// test ever touches the real Application Support directory — while the app wires
/// in the ``FileCatalogCacheStore``. A `load()` that cannot produce trustworthy
/// bytes returns `nil` (not a throw): a missing or unreadable cache is an
/// expected state that degrades to the bundled snapshot, never an error.
public protocol CatalogCacheStoring: Sendable {
    /// The current cache, or `nil` when none is present or it cannot be read.
    func load() -> CachedCatalog?
    /// Replace the cache atomically.
    func save(_ cached: CachedCatalog) throws
    /// Remove the cache (manual invalidation).
    func clear() throws
}

/// A ``CatalogCacheStoring`` backed by a directory under Application Support.
///
/// The payloads are written as their own files so the cache is inspectable and
/// the 18 MB cask document is not base64-inflated inside an envelope:
///
/// * `cask.json`      — raw API bytes;
/// * `analytics.json` — raw analytics bytes (optional);
/// * `meta.json`      — validators and the two dates.
///
/// `@unchecked Sendable` for the same reason as ``SystemFileSystem``:
/// `FileManager` is not annotated `Sendable`, but the operations used here hold
/// no shared mutable state and are safe to call from any thread.
public struct FileCatalogCacheStore: CatalogCacheStoring, @unchecked Sendable {

    private let directory: URL
    private let fileManager: FileManager

    private var caskURL: URL { directory.appendingPathComponent("cask.json") }
    private var analyticsURL: URL { directory.appendingPathComponent("analytics.json") }
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    /// - Parameter directory: the cache directory. Defaults to
    ///   `~/Library/Application Support/OpenFreshr/CatalogCache`.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base =
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory =
                base
                .appendingPathComponent("OpenFreshr", isDirectory: true)
                .appendingPathComponent("CatalogCache", isDirectory: true)
        }
    }

    /// The on-disk metadata envelope. Kept private so the internal ``Cask``
    /// `Codable` form is never involved in cache persistence — only opaque
    /// validators and dates are encoded here, never identity fields.
    private struct Meta: Codable {
        var caskValidators: CatalogValidators
        var analyticsValidators: CatalogValidators
        var fetchedAt: Date
        var checkedAt: Date
        var hasAnalytics: Bool
    }

    public func load() -> CachedCatalog? {
        // A cache is only usable with both its metadata and its cask payload; a
        // partial or unreadable cache degrades to `nil` (→ snapshot fallback),
        // it never throws and never fabricates data.
        guard let metaData = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
            let caskData = try? Data(contentsOf: caskURL)
        else {
            return nil
        }
        let analyticsData = meta.hasAnalytics ? try? Data(contentsOf: analyticsURL) : nil
        return CachedCatalog(
            caskAPIData: caskData,
            analyticsAPIData: analyticsData,
            caskValidators: meta.caskValidators,
            analyticsValidators: meta.analyticsValidators,
            fetchedAt: meta.fetchedAt,
            checkedAt: meta.checkedAt
        )
    }

    public func save(_ cached: CachedCatalog) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try cached.caskAPIData.write(to: caskURL, options: .atomic)
        if let analytics = cached.analyticsAPIData {
            try analytics.write(to: analyticsURL, options: .atomic)
        } else if fileManager.fileExists(atPath: analyticsURL.path) {
            try? fileManager.removeItem(at: analyticsURL)
        }
        let meta = Meta(
            caskValidators: cached.caskValidators,
            analyticsValidators: cached.analyticsValidators,
            fetchedAt: cached.fetchedAt,
            checkedAt: cached.checkedAt,
            hasAnalytics: cached.analyticsAPIData != nil
        )
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    public func clear() throws {
        for url in [caskURL, analyticsURL, metaURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
