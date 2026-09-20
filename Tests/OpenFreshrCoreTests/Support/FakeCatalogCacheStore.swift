import Foundation
@testable import OpenFreshrCore

/// An in-memory ``CatalogCacheStoring`` so the refresh flow is exercised with no
/// filesystem access at all — no test ever touches the real Application Support
/// directory.
///
/// It records how many times it was saved/cleared so a test can assert, e.g.,
/// that a `304` still rewrote the cache (to advance `checkedAt`) or that a failed
/// fetch never wrote at all.
///
/// `@unchecked Sendable`: the single stored value is serialised behind a lock.
final class FakeCatalogCacheStore: CatalogCacheStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: CachedCatalog?
    private var _saveCount = 0
    private var _clearCount = 0

    /// Optional hook to make ``save(_:)`` throw, to model a write failure.
    var saveError: Error?

    init(initial: CachedCatalog? = nil) {
        self.stored = initial
    }

    /// The currently stored cache, for assertions.
    var current: CachedCatalog? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Number of successful ``save(_:)`` calls.
    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _saveCount
    }

    /// Number of ``clear()`` calls.
    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _clearCount
    }

    func load() -> CachedCatalog? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ cached: CachedCatalog) throws {
        if let saveError { throw saveError }
        lock.lock(); defer { lock.unlock() }
        stored = cached
        _saveCount += 1
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
        _clearCount += 1
    }
}
