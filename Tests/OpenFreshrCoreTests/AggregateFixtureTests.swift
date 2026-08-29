import Foundation
import Testing
@testable import OpenFreshrCore

/// A single aggregate assertion over the **whole** regenerated fixture, derived
/// from real Homebrew cask data. Where the table-driven test proves individual
/// traps, this test guards the phase-1 head-line numbers so a silent regression
/// in ingestion, matching or the fail-closed gate (which would swing the
/// adoptable count to 3 or 58) is caught immediately.
struct AggregateFixtureTests {

    private func reports() throws -> [AppReport] {
        let coordinator = AdoptionCoordinator(
            scanner: InventoryScanner(fileSystem: FakeFileSystem(apps: try Fixture.installedApps())),
            backend: FakeBackend(available: false),
            catalog: CaskCatalog(casks: try Fixture.casks(), fetchedAt: Date()),
            scanDirectories: ["/Applications"]
        )
        return coordinator.makeReports()
    }

    @Test
    func phaseOneHeadlineMetricsHoldAgainstRealCaskData() throws {
        let reports = try reports()

        let adoptable = reports.filter { $0.eligibility.isEligible }
        let recognized = reports.filter { !$0.sources.isEmpty }

        // Emit the exact figures so the run itself documents them.
        print("[aggregate] apps=\(reports.count) adoptable=\(adoptable.count) recognized=\(recognized.count)")

        // Every scanned app is classified.
        #expect(reports.count == 109)

        // Adoptable count is a deterministic function of the checked-in fixture,
        // so it is pinned exactly rather than to a wide band. A tight assertion is
        // the point: the previous 34...44 window was broad enough to swallow a real
        // 3-app regression (e.g. 37 -> 33) unnoticed. Actual: 37 (Variant B — path
        // ids corroborate only as a fallback; strict Variant A would sink this to
        // 24). The domain-aware veto lifts this from 36 to 37 by no longer blocking
        // Raspberry Pi Imager, whose only cask id is a same-domain pre-rename id.
        #expect(adoptable.count == 37)

        // At least 100 of 109 apps are recognised via *some* source
        // (Mac App Store, Sparkle, a namespace updater, or a cask match).
        #expect(recognized.count >= 100)
    }

    // MARK: - At least one concrete case per exclusion reason

    @Test
    func eachExclusionReasonHasAConcreteRepresentative() throws {
        let reports = try reports()

        func report(_ bundleName: String) throws -> AppReport {
            try #require(reports.first { $0.app.bundleName == bundleName },
                         "fixture is missing \(bundleName)")
        }

        // pkg-only: Microsoft Defender ships inside the microsoft-office suite
        // cask, which installs via pkg — not losslessly adoptable.
        #expect(
            try report("Microsoft Defender.app").eligibility
                == .ineligible(reason: .caskIsInstallerOnly(caskToken: "microsoft-office"))
        )

        // MAS receipt: Microsoft Copilot is owned by the Mac App Store.
        #expect(
            try report("Copilot.app").eligibility
                == .ineligible(reason: .managedByMacAppStore)
        )

        // Veto (fail-closed on an unreadable identity): OnyX ships as the `onyx`
        // cask, which asserts com.titanium.OnyX ids, but the installed bundle has
        // no readable identifier. With nothing to recognise a rename by, the strong
        // artifact match is revoked rather than trusted.
        #expect(
            try report("OnyX.app").eligibility
                == .ineligible(reason: .strongMatchVetoed(caskToken: "onyx"))
        )

        // identityNotConfirmed (NOT a veto): `monitorcontrol` *is* MonitorControl's
        // own cask — its zap lists only the pre-rename ids (me.guillaumeb.*) while
        // the app is now app.monitorcontrol.MonitorControl. The domain-aware veto
        // recognises that rename (the old id's final label still names the app), so
        // the match is not revoked. But the cask auto-updates and the app id is not
        // corroborated (app.monitorcontrol vs me.guillaumeb genuinely differ), so
        // the fail-closed gate withholds it as unconfirmed rather than vetoed.
        #expect(
            try report("MonitorControl.app").eligibility
                == .ineligible(reason: .identityNotConfirmed(caskToken: "monitorcontrol"))
        )

        // noCaskMatch: a Microsoft internal app with no cask at all.
        if case .ineligible(.noCaskMatch) = try report("Clawpilot.app").eligibility {} else {
            Issue.record("expected Clawpilot.app to be noCaskMatch")
        }
    }

    // MARK: - The security-critical negative: Microsoft Copilot is never adoptable

    @Test
    func microsoftCopilotIsNeverInTheAdoptableSet() throws {
        let reports = try reports()

        // No eligible report may carry Microsoft Copilot's bundle identifier,
        // whichever app it is attached to.
        let offending = reports.filter {
            $0.eligibility.isEligible
                && ($0.app.bundleIdentifier ?? "").lowercased() == "com.microsoft.copilot-mac"
        }
        #expect(offending.isEmpty)

        // And specifically the Copilot.app bundle is not adoptable.
        let copilot = try #require(reports.first { $0.app.bundleName == "Copilot.app" })
        #expect(copilot.eligibility.isEligible == false)
        #expect(copilot.adoptableCaskToken != "copilot-money")
    }

    // MARK: - The security-critical positive: a renamed same-vendor app IS adoptable

    @Test
    func renamedSameOrgAppIsAdoptableThroughDomainAwareVeto() throws {
        let reports = try reports()

        // Raspberry Pi Imager is the mirror image of the Copilot trap. Its cask
        // `raspberry-pi-imager` records only a pre-rename cleanup id
        // (com.raspberrypi.imagingutility) while the installed app is
        // com.raspberrypi.rpi-imager — same organisation, renamed. The old, exact
        // veto blocked it outright; the domain-aware veto recognises the shared
        // com.raspberrypi domain and lets it through, where the cask's
        // auto_updates == false lets Homebrew's own version check backstop a wrong
        // adopt. It must be eligible, and specifically as its own cask.
        let imager = try #require(
            reports.first { $0.app.bundleName == "Raspberry Pi Imager.app" },
            "fixture is missing Raspberry Pi Imager.app"
        )
        #expect(imager.eligibility == .eligible(caskToken: "raspberry-pi-imager"))
    }
}
