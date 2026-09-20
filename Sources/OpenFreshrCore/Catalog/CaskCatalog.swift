import Foundation

/// An in-memory snapshot of cask definitions plus the moment it was fetched.
///
/// The age is kept so the app can show "catalog is N hours old" and decides when
/// to refresh. The catalog — and therefore the whole scan and match flow — works
/// with no network and even with Homebrew absent.
///
/// - Important: There is deliberately no way to build a catalog by decoding this
///   type's own `Codable` form. Doing so would let external JSON set stored
///   properties such as ``Cask/primaryBundleIdentifiers`` directly, which is the
///   identity that corroboration and the veto rely on — exactly the hole that an
///   earlier on-disk cache opened. Every catalog is built from the Homebrew API
///   shape through ``CaskCatalogIngestion``, which derives identity rather than
///   accepting it.
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

}
