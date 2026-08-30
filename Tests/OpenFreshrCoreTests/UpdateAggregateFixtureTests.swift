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

        // Split the offered updates by whether OpenFreshr may actually DRIVE them.
        // With nothing brew-managed here (idle runner → empty `brew list --cask`),
        // every offered Homebrew update is only *adoptable*, so after the fix none
        // is executable and all are marked "requires adoption first". This is the
        // Amazon-Photos guarantee at fixture scale: the newer version is still
        // reported (offered is unchanged), only the action is withheld.
        let executable = reports.filter { report in report.sources.contains { $0.isDrivable } }
        let requiresAdoption = reports.filter { $0.requiresAdoptionForUpdate }

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
        [update-aggregate] executable=\(executable.count) requiresAdoption=\(requiresAdoption.count)
        offered apps: \(offered.map { $0.app.displayName }.sorted())
        requires adoption: \(requiresAdoption.map { $0.app.displayName }.sorted())
        """)

        // Pins the headline count. If the fixture or comparator changes on
        // purpose, update these numbers and the reported figures together.
        #expect(reports.count == 109)
        #expect(offered.count == 17)
        #expect(major.count == 5)

        // The fix's headline: with no cask managed, nothing is executable and all
        // 17 offered updates require adoption first (offered stays 17 — the
        // information is untouched, only the action changed).
        #expect(executable.count == 0)
        #expect(requiresAdoption.count == 17)
        #expect(requiresAdoption.count == offered.count)
    }

    /// The counter-scenario to ``offeredUpdatesHoldAgainstTheReferenceSnapshot``:
    /// mark exactly **one** of the offered casks as brew-managed (mirroring the
    /// reference system, where 37 apps are adoptable but only a single one is
    /// actually managed). That one becomes executable; the other 16 stay
    /// "requires adoption first". This proves the managed/adoptable split end to
    /// end over real fixture data, not just a synthetic app.
    @Test
    func exactlyTheManagedCaskBecomesExecutableEverythingElseNeedsAdoption() async throws {
        let apps = try Fixture.installedApps()
        let casks = try Fixture.casks()

        var fs = FakeFileSystem()
        fs.addExistingPath("/opt/homebrew/bin/brew")

        // `brew list --cask -1` reports Obsidian (an offered app) as managed;
        // everything else is merely adoptable. `brew upgrade` succeeds if asked.
        let runner = RecordingProcessRunner { _, args in
            if args == ["list", "--cask", "-1"] {
                return ProcessResult(exitCode: 0, standardOutput: "obsidian\n", standardError: "")
            }
            return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }

        let coordinator = UpdateCoordinator(
            scanner: ScriptedScanner(apps: apps),
            homebrew: HomebrewBackend(processRunner: runner, fileSystem: fs),
            macAppStore: MacAppStoreBackend(processRunner: runner, fileSystem: fs),
            microsoftAutoUpdate: MicrosoftAutoUpdateBackend(processRunner: runner, fileSystem: fs),
            catalog: CaskCatalog(casks: casks, fetchedAt: Date()),
            httpFetcher: FakeHTTPFetcher(),
            scanDirectories: ["/Applications"]
        )

        let reports = await coordinator.makeUpdateReports()
        let offered = reports.filter { $0.hasUpdate }
        let executable = reports.filter { report in report.sources.contains { $0.isDrivable } }
        let requiresAdoption = reports.filter { $0.requiresAdoptionForUpdate }

        // The offered set is unchanged by what is managed — only the action is.
        #expect(offered.count == 17)
        // Exactly the one managed cask (Obsidian) is now executable…
        #expect(executable.count == 1)
        #expect(executable.first?.app.displayName == "Obsidian")
        #expect(executable.first?.sources.contains { $0.isDrivable && $0.backend == .homebrew } == true)
        // …and the remaining 16 offered updates still require adoption first.
        #expect(requiresAdoption.count == 16)
        #expect(requiresAdoption.contains { $0.app.displayName == "Amazon Photos" })
        #expect(requiresAdoption.allSatisfy { $0.app.displayName != "Obsidian" })
    }
}
