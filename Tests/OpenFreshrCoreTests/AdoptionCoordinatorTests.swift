import Foundation
import Testing

@testable import OpenFreshrCore

/// The end-to-end phase 1 sequence **scan → match → adopt → rescan → confirm**,
/// with a fake backend and a fake filesystem so nothing touches `/Applications`
/// or the real `brew`. The theme throughout: success is asserted *only* by a
/// confirming rescan, and a `CaskError` hard-fail stays distinct from a no-op.
struct AdoptionCoordinatorTests {

    private func coordinator(
        apps: [InstalledApp],
        backend: FakeBackend
    ) throws -> AdoptionCoordinator {
        AdoptionCoordinator(
            scanner: InventoryScanner(fileSystem: FakeFileSystem(apps: apps)),
            backend: backend,
            catalog: CaskCatalog(casks: try Fixture.casks(), fetchedAt: Date()),
            scanDirectories: ["/Applications"]
        )
    }

    // MARK: - Reporting

    @Test
    func makeReportsClassifiesEveryScannedApp() throws {
        let apps = try Fixture.installedApps()
        let reports = try coordinator(apps: apps, backend: FakeBackend()).makeReports()

        #expect(reports.count == apps.count)

        let copilot = try #require(reports.first { $0.app.bundleName == "Copilot.app" })
        #expect(copilot.eligibility == .ineligible(reason: .managedByMacAppStore))

        let onePassword = try #require(reports.first { $0.app.bundleName == "1Password.app" })
        #expect(onePassword.eligibility == .eligible(caskToken: "1password"))
        // The predicted outcome is advisory and mirrors the auto-updating cask.
        #expect(onePassword.predictedOutcome == .succeedsUnconditionally)
    }

    @Test
    func scanAndReportWorkWithHomebrewAbsent() throws {
        let apps = try Fixture.installedApps()
        // brew missing: unavailable backend, empty managed set.
        let backend = FakeBackend(available: false)
        let reports = try coordinator(apps: apps, backend: backend).makeReports()

        // The scan still classifies everything; a missing brew degrades rather
        // than blocks. 1Password remains eligible because nothing is flagged as
        // already-managed.
        #expect(reports.count == apps.count)
        let onePassword = try #require(reports.first { $0.app.bundleName == "1Password.app" })
        #expect(onePassword.eligibility == .eligible(caskToken: "1password"))
    }

    @Test
    func managedCaskTokenIsSetOnlyForAnAlreadyManagedHomebrewSource() throws {
        let apps = try Fixture.installedApps()

        let managedReports = try coordinator(apps: apps, backend: FakeBackend(managed: ["1password"]))
            .makeReports()
        let managedOnePassword = try #require(managedReports.first { $0.app.bundleName == "1Password.app" })
        #expect(managedOnePassword.managedCaskToken == "1password")

        // Unmanaged: matched but not yet adopted — the Uninstall gate must not
        // fire for a mere suggestion.
        let unmanagedReports = try coordinator(apps: apps, backend: FakeBackend()).makeReports()
        let unmanagedOnePassword = try #require(unmanagedReports.first { $0.app.bundleName == "1Password.app" })
        #expect(unmanagedOnePassword.managedCaskToken == nil)
    }

    @Test
    func isSafelyAdoptableIsTrueOnlyForAnUnmanagedAppThatWouldNotAbort() throws {
        let apps = try Fixture.installedApps()
        let reports = try coordinator(apps: apps, backend: FakeBackend()).makeReports()

        // 1Password: auto_updates cask, unmanaged — succeeds unconditionally.
        let onePassword = try #require(reports.first { $0.app.bundleName == "1Password.app" })
        #expect(onePassword.predictedOutcome == .succeedsUnconditionally)
        #expect(onePassword.isSafelyAdoptable)

        // Amazon Photos: a real regression fixture where the take-over is
        // predicted to abort with a CaskError — never offered a one-click button.
        let amazonPhotos = try #require(reports.first { $0.app.bundleName == "Amazon Photos.app" })
        #expect(amazonPhotos.predictedOutcome == .abortsWithCaskError)
        #expect(!amazonPhotos.isSafelyAdoptable)

        // Already managed: never adoptable again, regardless of prediction.
        let managedReports = try coordinator(apps: apps, backend: FakeBackend(managed: ["1password"]))
            .makeReports()
        let managedOnePassword = try #require(managedReports.first { $0.app.bundleName == "1Password.app" })
        #expect(!managedOnePassword.isSafelyAdoptable)
    }

    // MARK: - Adoption confirmed only by rescan

    @Test
    func adoptSucceedsOnlyAfterRescanConfirmsHomebrewManagement() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        // A successful adopt that flips the token into the managed set — the
        // rescan will corroborate it.
        let backend = FakeBackend(
            adoptResult: .succeeded(standardOutput: "ok"),
            adoptBecomesManaged: true)

        let result = try coordinator(apps: apps, backend: backend).adopt(onePassword)

        guard case let .adopted(report) = result else {
            Issue.record("expected .adopted, got \(result)")
            return
        }
        #expect(report.app.bundleName == "1Password.app")
        #expect(result.didAdopt)
        #expect(result.isRetryable == false)
        #expect(backend.adoptCalls.map(\.token) == ["1password"])
    }

    @Test
    func backendSuccessNotCorroboratedByRescanIsNotAdopted() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        // The backend claims success but the token never appears in `brew list`.
        let backend = FakeBackend(
            adoptResult: .succeeded(standardOutput: "ok"),
            adoptBecomesManaged: false)

        let result = try coordinator(apps: apps, backend: backend).adopt(onePassword)

        // A "success" the rescan does not confirm is never reported as done.
        guard case .notConfirmedByRescan = result else {
            Issue.record("expected .notConfirmedByRescan, got \(result)")
            return
        }
        #expect(result.isRetryable)
        #expect(result.didAdopt == false)
    }

    // MARK: - CaskError stays distinct from "nothing happened"

    @Test
    func caskErrorIsReportedDistinctlyAndIsRetryable() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        let backend = FakeBackend(
            adoptResult: .caskError(message: "CaskError: version mismatch"),
            adoptBecomesManaged: false)

        let result = try coordinator(apps: apps, backend: backend).adopt(onePassword)

        guard case let .hardFailedWithCaskError(message) = result else {
            Issue.record("expected .hardFailedWithCaskError, got \(result)")
            return
        }
        #expect(message == "CaskError: version mismatch")
        #expect(result.isRetryable)
        // The decisive contrast with notConfirmedByRescan: a CaskError is a known
        // hard-fail, not a silent no-op.
        #expect(result.didAdopt == false)
    }

    @Test
    func genericBackendFailureIsPropagated() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        let backend = FakeBackend(
            adoptResult: .failed(reason: .processFailed(exitCode: 1, standardError: "boom")),
            adoptBecomesManaged: false
        )

        let result = try coordinator(apps: apps, backend: backend).adopt(onePassword)

        guard case let .failed(reason) = result, case .processFailed = reason else {
            Issue.record("expected .failed(.processFailed), got \(result)")
            return
        }
        #expect(result.isRetryable)
    }

    // MARK: - Ineligible apps are refused before any backend call

    @Test
    func ineligibleAppIsNeverSentToTheBackend() throws {
        let apps = try Fixture.installedApps()
        let copilot = try #require(Fixture.app(named: "Copilot.app", in: apps))
        let backend = FakeBackend()

        let result = try coordinator(apps: apps, backend: backend).adopt(copilot)

        guard case let .notEligible(reason) = result else {
            Issue.record("expected .notEligible, got \(result)")
            return
        }
        #expect(reason == .managedByMacAppStore)
        #expect(result.isRetryable == false)
        // The dangerous cask must never even be handed to `brew`.
        #expect(backend.adoptCalls.isEmpty)
    }

    @Test
    func vetoedCopilotWithoutMASReceiptIsRefusedBeforeBackend() throws {
        var apps = try Fixture.installedApps()
        // Remove the MAS receipt so the veto is the only thing left to block it,
        // then prove the coordinator still refuses to call the backend.
        let index = try #require(apps.firstIndex { $0.bundleName == "Copilot.app" })
        apps[index].hasMacAppStoreReceipt = false
        let copilot = apps[index]
        let backend = FakeBackend()

        let result = try coordinator(apps: apps, backend: backend).adopt(copilot)

        guard case let .notEligible(reason) = result else {
            Issue.record("expected .notEligible, got \(result)")
            return
        }
        #expect(reason == .strongMatchVetoed(caskToken: "copilot-money"))
        #expect(backend.adoptCalls.isEmpty)
    }
}
