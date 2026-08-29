import Foundation
import Testing
@testable import OpenFreshrCore

/// The update-side analogue of ``AggregateFixtureTests``: it runs the whole
/// detection pipeline over the frozen 109-app / 58-cask reference snapshot and
/// pins the headline number — *how many apps OpenFreshr would offer an update
/// for* — so a regression in the comparator, the matcher or the resolver shows
/// up as a moved count rather than a silent drift.
///
/// The environment mirrors a real first run with **no help from the network or
/// the auxiliary tools**: Homebrew is installed, `mas` and `msupdate` are absent,
/// and every Sparkle feed is unreachable. So the only *offered* updates are the
/// ones Homebrew can prove: an app OpenFreshr confidently attributes to a cask
/// whose version is comparably newer than what is installed. Everything else is
/// either up to date or honestly `unbekannt`.
struct UpdateAggregateFixtureTests {

    @Test
    func offeredUpdatesHoldAgainstTheReferenceSnapshot() async throws {
        let apps = try Fixture.installedApps()
        let casks = try Fixture.casks()

        var fs = FakeFileSystem()
        fs.addExistingPath("/opt/homebrew/bin/brew") // brew present; mas + msupdate absent

        let idle = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }

        let coordinator = UpdateCoordinator(
            scanner: ScriptedScanner(apps: apps),
            homebrew: HomebrewBackend(processRunner: idle, fileSystem: fs),
            macAppStore: MacAppStoreBackend(processRunner: idle, fileSystem: fs),
            microsoftAutoUpdate: MicrosoftAutoUpdateBackend(processRunner: idle, fileSystem: fs),
            catalog: CaskCatalog(casks: casks, fetchedAt: Date()),
            httpFetcher: FakeHTTPFetcher(), // every feed unreachable
            scanDirectories: ["/Applications"]
        )

        let reports = await coordinator.makeUpdateReports()

        let offered = reports.filter { $0.hasUpdate }
        let major = reports.filter { $0.hasMajorUpdate }
        let selfUpdating = reports.filter { $0.isSelfUpdating }
        let unassigned = reports.filter { $0.isUnassigned }
        let withProblem = reports.filter { $0.hasSourceProblem }

        // Every offered update is Homebrew-driven in this toolless environment,
        // and never a Sparkle source (those carry no command by construction).
        for report in offered {
            let driving = report.sources.filter { $0.state.hasUpdate }
            #expect(driving.allSatisfy { $0.backend == .homebrew },
                    "\(report.app.displayName) offered a non-Homebrew update without its tool")
        }

        // No offered update may be built on an incomparable version — the hard
        // "never a false update" rule, checked across the whole snapshot.
        for report in reports {
            for source in report.sources where source.state.hasUpdate {
                #expect(source.state.availableVersion != nil)
            }
        }

        print("""
        [update-aggregate] apps=\(reports.count) \
        offered=\(offered.count) major=\(major.count) \
        selfUpdating=\(selfUpdating.count) unassigned=\(unassigned.count) \
        sourceProblem=\(withProblem.count)
        offered apps: \(offered.map { $0.app.displayName }.sorted())
        """)

        // Pins the headline count. If the fixture or comparator changes on
        // purpose, update these numbers and the reported figures together.
        #expect(reports.count == 109)
        #expect(offered.count == 17)
        #expect(major.count == 5)
    }
}
