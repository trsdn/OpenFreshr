import Foundation
import Testing

@testable import OpenFreshrCore

/// The install coordinator (Phase 5): **install → local scan → confirm**. Success
/// is asserted only by a rescan that finds the app on disk (or, for an
/// installer-only cask, a brew receipt); a backend "success" the scan does not
/// corroborate is never reported as done. Each call is independent, so one cask
/// failing leaves another installable.
struct InstallCoordinatorTests {

    private let scanDirectories = ["/Applications"]

    private func appCask(
        _ token: String = "example",
        target: String = "Example.app"
    ) -> Cask {
        Cask(
            token: token, names: [token.capitalized],
            artifacts: [CaskArtifact(kind: .app, target: target)])
    }

    private func pkgCask(_ token: String = "installeronly") -> Cask {
        Cask(
            token: token, names: [token.capitalized],
            artifacts: [CaskArtifact(kind: .pkg)])
    }

    private func installedApp(_ path: String) -> InstalledApp {
        InstalledApp(bundlePath: path, bundleIdentifier: "com.example.app")
    }

    // MARK: - success only after a confirming rescan (app casks)

    @Test
    func reportsInstalledOnlyWhenRescanFindsTheAppOnDisk() {
        let backend = FakeBackend(managed: [])
        // The post-install scan shows the app now on disk.
        let scanner = ScriptedScanner(apps: [installedApp("/Applications/Example.app")])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        let result = coordinator.install(appCask())

        guard case let .installed(app) = result else {
            Issue.record("expected .installed, got \(result)")
            return
        }
        #expect(app.bundlePath == "/Applications/Example.app")
        #expect(result.didInstall)
        #expect(backend.installCalls == ["example"])
        #expect(scanner.scanCount == 1)  // exactly one confirming rescan
    }

    @Test
    func backendSuccessIsNotConfirmedWhenRescanMissesTheApp() {
        let backend = FakeBackend(managed: [])  // install "succeeds"…
        let scanner = ScriptedScanner(apps: [])  // …but nothing is on disk
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        let result = coordinator.install(appCask())

        #expect(result == .notConfirmedByRescan)
        #expect(result.didInstall == false)
        #expect(result.isRetryable)
    }

    // MARK: - installer-only casks: confirmed by the brew receipt

    @Test
    func installerOnlyCaskIsConfirmedByTheBrewReceipt() {
        // No app bundle is ever dropped, so the scan stays empty; the receipt
        // (the token becoming managed) is the confirming signal.
        let backend = FakeBackend(managed: [], installBecomesManaged: true)
        let scanner = ScriptedScanner(apps: [])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        let result = coordinator.install(pkgCask("installeronly"))

        #expect(result == .installedInstaller(token: "installeronly"))
        #expect(result.didInstall)
    }

    @Test
    func installerOnlyCaskIsNotConfirmedWhenReceiptIsAbsent() {
        let backend = FakeBackend(managed: [], installBecomesManaged: false)
        let scanner = ScriptedScanner(apps: [])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        #expect(coordinator.install(pkgCask()) == .notConfirmedByRescan)
    }

    // MARK: - failure classification

    @Test
    func caskErrorFromBackendIsSurfacedAsAHardFail() {
        let backend = FakeBackend(installResult: .caskError(message: "CaskError: nope"))
        let scanner = ScriptedScanner(apps: [])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        guard case let .hardFailedWithCaskError(message) = coordinator.install(appCask()) else {
            Issue.record("expected a hard fail with the CaskError")
            return
        }
        #expect(message.contains("CaskError"))
        #expect(scanner.scanCount == 0)  // a hard fail never pretends to rescan
    }

    @Test
    func alreadyManagedCaskIsRefusedWithoutInstalling() {
        let backend = FakeBackend(managed: ["example"])
        let scanner = ScriptedScanner(apps: [])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        #expect(coordinator.install(appCask("example")) == .alreadyInstalled(token: "example"))
        #expect(backend.installCalls.isEmpty)  // nothing ran
    }

    // MARK: - invalid token: refused, never reaching `brew install`

    @Test
    func invalidTokenIsRejectedAndNeverReachesBrewInstall() {
        var fs = FakeFileSystem()
        fs.addExistingPath("/opt/homebrew/bin/brew")
        let runner = RecordingProcessRunner { _, arguments in
            // The managed-set precheck may run `brew list`, but a `brew install`
            // for the hostile token must never happen.
            if arguments.first == "install" {
                Issue.record("brew install must never run for an invalid token")
            }
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let backend = HomebrewBackend(processRunner: runner, fileSystem: fs)
        let scanner = ScriptedScanner(apps: [])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        let hostile = Cask(
            token: "--force", names: ["Evil"],
            artifacts: [CaskArtifact(kind: .app, target: "Evil.app")])
        let result = coordinator.install(hostile)

        guard case let .failed(reason) = result, case .invalidCaskToken = reason else {
            Issue.record("expected .failed(.invalidCaskToken), got \(result)")
            return
        }
        #expect(runner.invocations.allSatisfy { $0.arguments.first != "install" })
    }

    // MARK: - per-cask error isolation

    @Test
    func oneCaskFailingLeavesAnotherInstallable() {
        // The same coordinator handles both casks. A failure on the first must
        // not leave sticky state that blocks the second — each install() is
        // independent.
        let backend = FakeBackend(managed: [])
        let scanner = ScriptedScanner(apps: [installedApp("/Applications/Good.app")])
        let coordinator = InstallCoordinator(
            scanner: scanner, backend: backend, scanDirectories: scanDirectories
        )

        backend.installResult = .failed(reason: .processFailed(exitCode: 1, standardError: "boom"))
        let first = coordinator.install(appCask("bad", target: "Bad.app"))
        #expect(first.didInstall == false)

        // A wholly separate cask still installs cleanly afterwards.
        backend.installResult = .succeeded(standardOutput: "ok")
        let second = coordinator.install(appCask("good", target: "Good.app"))
        guard case let .installed(app) = second else {
            Issue.record("the second, unrelated cask must still install; got \(second)")
            return
        }
        #expect(app.bundlePath == "/Applications/Good.app")
    }
}
