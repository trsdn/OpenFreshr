import Foundation
@testable import OpenFreshrCore

/// A programmable ``AdoptingBackend`` for coordinator tests.
///
/// Its distinctive feature is ``adoptBecomesManaged``: when set, a *successful*
/// adopt flips the token into ``managedTokens()`` — modelling the real world
/// where success only becomes observable on the next `brew list`. That lets the
/// coordinator's "confirm by rescan" contract be tested from both sides: a
/// backend success that the rescan corroborates (token now managed) versus one
/// it does not (token still absent).
///
/// `@unchecked Sendable`: mutable state is serialised behind a lock.
final class FakeBackend: AdoptingBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var _managed: Set<String>
    private var _adoptCalls: [(bundlePath: String, token: String)] = []
    private var _updateCalls: [String] = []

    var available: Bool
    var adoptResult: BackendActionResult
    /// When `true`, a successful adopt adds its token to the managed set.
    var adoptBecomesManaged: Bool
    /// Result returned by ``update(identifier:)``. Defaults to success.
    var updateResult: BackendActionResult

    init(
        available: Bool = true,
        managed: Set<String> = [],
        adoptResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        adoptBecomesManaged: Bool = true,
        updateResult: BackendActionResult = .succeeded(standardOutput: "ok")
    ) {
        self.available = available
        self._managed = managed
        self.adoptResult = adoptResult
        self.adoptBecomesManaged = adoptBecomesManaged
        self.updateResult = updateResult
    }

    var adoptCalls: [(bundlePath: String, token: String)] {
        lock.lock(); defer { lock.unlock() }
        return _adoptCalls
    }

    var updateCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _updateCalls
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

    func resolveUpdateCommand(identifier: String) -> ResolvedCommand? {
        guard available else { return nil }
        return ResolvedCommand(
            executablePath: "/opt/homebrew/bin/brew",
            arguments: ["upgrade", "--cask", "--greedy", "--", identifier]
        )
    }

    func update(identifier: String) -> BackendActionResult {
        lock.lock()
        _updateCalls.append(identifier)
        lock.unlock()
        return updateResult
    }
}
