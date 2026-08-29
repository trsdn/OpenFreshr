import Foundation
@testable import OpenFreshrCore

/// A programmable ``PackageBackend`` for coordinator tests.
///
/// Its distinctive feature is ``adoptBecomesManaged``: when set, a *successful*
/// adopt flips the token into ``managedTokens()`` — modelling the real world
/// where success only becomes observable on the next `brew list`. That lets the
/// coordinator's "confirm by rescan" contract be tested from both sides: a
/// backend success that the rescan corroborates (token now managed) versus one
/// it does not (token still absent).
///
/// `@unchecked Sendable`: mutable state is serialised behind a lock.
final class FakeBackend: PackageBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var _managed: Set<String>
    private var _adoptCalls: [(bundlePath: String, token: String)] = []

    var available: Bool
    var adoptResult: BackendActionResult
    /// When `true`, a successful adopt adds its token to the managed set.
    var adoptBecomesManaged: Bool

    init(
        available: Bool = true,
        managed: Set<String> = [],
        adoptResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        adoptBecomesManaged: Bool = true
    ) {
        self.available = available
        self._managed = managed
        self.adoptResult = adoptResult
        self.adoptBecomesManaged = adoptBecomesManaged
    }

    var adoptCalls: [(bundlePath: String, token: String)] {
        lock.lock(); defer { lock.unlock() }
        return _adoptCalls
    }

    func isAvailable() -> Bool { available }

    func managedTokens() -> Set<String> {
        guard available else { return [] }
        lock.lock(); defer { lock.unlock() }
        return _managed
    }

    func adopt(app: InstalledApp, caskToken: String) -> BackendActionResult {
        lock.lock()
        _adoptCalls.append((app.bundlePath, caskToken))
        if adoptResult.didReportSuccess, adoptBecomesManaged {
            _managed.insert(caskToken)
        }
        lock.unlock()
        return adoptResult
    }
}
