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
final class FakeBackend: AdoptingBackend, InstallingBackend, UninstallingBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var _managed: Set<String>
    private var _adoptCalls: [(bundlePath: String, token: String)] = []
    private var _updateCalls: [String] = []
    private var _installCalls: [String] = []
    private var _uninstallCalls: [String] = []

    var available: Bool
    var adoptResult: BackendActionResult
    /// When `true`, a successful adopt adds its token to the managed set.
    var adoptBecomesManaged: Bool
    /// Result returned by ``update(identifier:)``. Defaults to success.
    var updateResult: BackendActionResult
    /// Result returned by ``install(caskToken:)``. Defaults to success.
    var installResult: BackendActionResult
    /// When `true`, a successful install adds its token to the managed set —
    /// modelling the brew receipt an installer-only cask leaves behind, which is
    /// how the coordinator confirms a cask that drops no app bundle to find.
    var installBecomesManaged: Bool
    /// Result returned by ``uninstall(caskToken:)``. Defaults to success.
    var uninstallResult: BackendActionResult
    /// When `true`, a successful uninstall removes its token from the managed
    /// set — modelling the real world where success only becomes observable on
    /// the next `brew list`. `false` lets a test model a reported success the
    /// recheck does not corroborate.
    var uninstallBecomesUnmanaged: Bool

    init(
        available: Bool = true,
        managed: Set<String> = [],
        adoptResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        adoptBecomesManaged: Bool = true,
        updateResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        installResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        installBecomesManaged: Bool = true,
        uninstallResult: BackendActionResult = .succeeded(standardOutput: "ok"),
        uninstallBecomesUnmanaged: Bool = true
    ) {
        self.available = available
        self._managed = managed
        self.adoptResult = adoptResult
        self.adoptBecomesManaged = adoptBecomesManaged
        self.updateResult = updateResult
        self.installResult = installResult
        self.installBecomesManaged = installBecomesManaged
        self.uninstallResult = uninstallResult
        self.uninstallBecomesUnmanaged = uninstallBecomesUnmanaged
    }

    var adoptCalls: [(bundlePath: String, token: String)] {
        lock.lock(); defer { lock.unlock() }
        return _adoptCalls
    }

    var updateCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _updateCalls
    }

    var installCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _installCalls
    }

    var uninstallCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _uninstallCalls
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

    func resolveInstallCommand(identifier: String) -> ResolvedCommand? {
        guard available else { return nil }
        return ResolvedCommand(
            executablePath: "/opt/homebrew/bin/brew",
            arguments: ["install", "--cask", "--", identifier]
        )
    }

    func install(caskToken: String) -> BackendActionResult {
        lock.lock()
        _installCalls.append(caskToken)
        if installResult.didReportSuccess, installBecomesManaged {
            _managed.insert(caskToken)
        }
        lock.unlock()
        return installResult
    }

    func resolveUninstallCommand(identifier: String) -> ResolvedCommand? {
        guard available else { return nil }
        return ResolvedCommand(
            executablePath: "/opt/homebrew/bin/brew",
            arguments: ["uninstall", "--cask", "--", identifier]
        )
    }

    func uninstall(caskToken: String) -> BackendActionResult {
        lock.lock()
        _uninstallCalls.append(caskToken)
        if uninstallResult.didReportSuccess, uninstallBecomesUnmanaged {
            _managed.remove(caskToken)
        }
        lock.unlock()
        return uninstallResult
    }
}
