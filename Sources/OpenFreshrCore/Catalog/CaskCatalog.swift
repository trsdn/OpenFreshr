import Foundation

/// An in-memory snapshot of cask definitions plus the moment it was fetched.
///
/// The age is kept so the app can show "catalog is N hours old" and a later
/// phase can decide when to refresh. Phase 1 loads this from a bundled/cached
/// JSON file, so the catalog — and therefore the whole scan and match flow —
/// works with no network and even with Homebrew absent.
public struct CaskCatalog: Sendable {

    public var casks: [Cask]
    public var fetchedAt: Date

    public init(casks: [Cask], fetchedAt: Date) {
        self.casks = casks
        self.fetchedAt = fetchedAt
    }

    /// Age of the snapshot relative to `now` (default: the current time).
    public func age(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(fetchedAt)
    }

    /// Decode a catalog from the raw JSON of an array of ``Cask`` values.
    public static func decode(from data: Data, fetchedAt: Date) throws -> CaskCatalog {
        let casks = try JSONDecoder().decode([Cask].self, from: data)
        return CaskCatalog(casks: casks, fetchedAt: fetchedAt)
    }
}
