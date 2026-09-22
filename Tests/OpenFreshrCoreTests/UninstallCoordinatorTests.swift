import Foundation
import Testing

@testable import OpenFreshrCore

/// The uninstall coordinator (#40): **verify managed → uninstall → confirm**.
/// Success is asserted only when a recheck shows the token no longer managed; a
/// backend "success" the recheck does not corroborate is never reported as
/// done. A token that was never managed is refused before any process runs.
struct UninstallCoordinatorTests {

    @Test
    func reportsUninstalledOnlyWhenTheTokenIsNoLongerManagedAfterward() {
        let backend = FakeBackend(managed: ["example"])
        let coordinator = UninstallCoordinator(backend: backend)

        let result = coordinator.uninstall(caskToken: "example")

        #expect(result == .uninstalled(caskToken: "example"))
        #expect(result.didUninstall)
        #expect(backend.uninstallCalls == ["example"])
        #expect(!backend.managedTokens().contains("example"))
    }

    @Test
    func refusesATokenThatIsNotManagedWithoutRunningAnyProcess() {
        let backend = FakeBackend(managed: [])
        let coordinator = UninstallCoordinator(backend: backend)

        let result = coordinator.uninstall(caskToken: "example")

        #expect(result == .notManaged(caskToken: "example"))
        #expect(!result.didUninstall)
        #expect(!result.isRetryable)
        #expect(backend.uninstallCalls.isEmpty)
    }

    @Test
    func backendSuccessIsNotConfirmedWhenTheTokenIsStillManagedAfterward() {
        let backend = FakeBackend(managed: ["example"], uninstallBecomesUnmanaged: false)
        let coordinator = UninstallCoordinator(backend: backend)

        let result = coordinator.uninstall(caskToken: "example")

        #expect(result == .notConfirmedByRescan)
        #expect(!result.didUninstall)
        #expect(result.isRetryable)
        #expect(backend.uninstallCalls == ["example"])
    }

    @Test
    func aCaskErrorIsReportedDistinctlyAndTheTokenStaysManaged() {
        let backend = FakeBackend(
            managed: ["example"],
            uninstallResult: .caskError(message: "Error: Cask 'example' is not installed.")
        )
        let coordinator = UninstallCoordinator(backend: backend)

        let result = coordinator.uninstall(caskToken: "example")

        guard case .hardFailedWithCaskError = result else {
            Issue.record("expected .hardFailedWithCaskError, got \(result)")
            return
        }
        #expect(result.isRetryable)
        #expect(backend.managedTokens().contains("example"))
    }

    @Test
    func anOrdinaryFailureIsReportedAndTheTokenStaysManaged() {
        let backend = FakeBackend(
            managed: ["example"],
            uninstallResult: .failed(reason: .requiresAdministratorPrivileges)
        )
        let coordinator = UninstallCoordinator(backend: backend)

        let result = coordinator.uninstall(caskToken: "example")

        #expect(result == .failed(reason: .requiresAdministratorPrivileges))
        #expect(result.isRetryable)
        #expect(backend.managedTokens().contains("example"))
    }
}
