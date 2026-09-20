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
        // Nothing is brew-managed here (idle runner → empty `brew list --cask`), so
        // every offered Homebrew update is *adoptable*. After the merge, an app
        // whose cask auto-updates (or matches versions) becomes a drivable, single
        // "Aktualisieren" that runs `install --cask --adopt` then `reinstall --cask`;
        // only an app that Homebrew would refuse to adopt (`auto_updates == false`
        // with a version mismatch — the Amazon-Photos trap) stays non-executable and
        // is honestly named "über den Hersteller". The offered set is unchanged
        // either way — the information is untouched, only the action.
        let executable = reports.filter { report in report.sources.contains { $0.isDrivable } }
        let adoptionWouldFail = reports.filter { $0.adoptionWouldFailForUpdate }

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
        [update-aggregate] executable=\(executable.count) adoptionWouldFail=\(adoptionWouldFail.count)
        offered apps: \(offered.map { $0.app.displayName }.sorted())
        executable: \(executable.map { $0.app.displayName }.sorted())
        adoption would fail: \(adoptionWouldFail.map { $0.app.displayName }.sorted())
        """)

        // Pins the headline count. If the fixture or comparator changes on
        // purpose, update these numbers and the reported figures together.
        #expect(reports.count == 109)
        #expect(offered.count == 17)
        #expect(major.count == 5)

        // The fix's headline: with nothing managed, the merged "Aktualisieren"
        // makes every adoptable update executable — except the ones Homebrew would
        // refuse to adopt, which stay non-executable and honestly named. The two
        // partition the 17 offered updates (offered stays 17 — only the action
        // changed, never the information). 11 become executable (was 0); the
        // remaining 6 (auto_updates == false with a version drift) stay refused.
        #expect(executable.count == 11)
        #expect(adoptionWouldFail.count == 6)
        #expect(executable.count + adoptionWouldFail.count == offered.count)
    }

    /// The counter-scenario to ``offeredUpdatesHoldAgainstTheReferenceSnapshot``:
    /// mark exactly **one** of the offered casks as brew-managed (mirroring the
    /// reference system, where many apps are adoptable but only a few are actually
    /// managed). It stays executable — but now via the direct `upgrade` path rather
    /// than the adopt-then-reinstall merge — while every *other* adoptable app is
    /// **also** executable through the merge, and only the apps Homebrew would
    /// refuse to adopt stay non-executable. This proves the managed/adoptable/refused
    /// split end to end over real fixture data, not just a synthetic app.
    @Test
    func theManagedCaskUpgradesWhileAdoptablePeersMergeAndRefusedOnesStayBlocked() async throws {
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
        let adoptionWouldFail = reports.filter { $0.adoptionWouldFailForUpdate }

        // The offered set is unchanged by what is managed — only *how* it is driven.
        #expect(offered.count == 17)

        // Obsidian is executable via the direct managed upgrade (one command),
        // NOT the adopt-then-reinstall merge.
        let obsidian = try #require(reports.first { $0.app.displayName == "Obsidian" })
        let obsidianSource = try #require(obsidian.sources.first { $0.backend == .homebrew })
        #expect(obsidianSource.isDrivable)
        #expect(obsidianSource.homebrewStrategy == .upgrade)
        #expect(obsidianSource.commandPlan.count == 1)

        // An adoptable peer that Homebrew can take over is executable via the merge
        // (two commands: adopt then reinstall).
        let mergedPeers = reports.filter { report in
            report.sources.contains { $0.isDrivable && $0.homebrewStrategy == .adoptThenReinstall }
        }
        #expect(mergedPeers.contains { $0.app.displayName != "Obsidian" })
        for peer in mergedPeers {
            let source = try #require(peer.sources.first { $0.homebrewStrategy == .adoptThenReinstall })
            #expect(source.commandPlan.count == 2)
        }

        // The refused apps (Amazon Photos among them) stay non-executable, exactly
        // as in the toolless run — managing Obsidian does not change them.
        #expect(adoptionWouldFail.contains { $0.app.displayName == "Amazon Photos" })
        #expect(adoptionWouldFail.allSatisfy { $0.app.displayName != "Obsidian" })

        // The whole snapshot still partitions: every offered update is either
        // executable or a predicted-refused adoption.
        #expect(executable.count == 11)
        #expect(adoptionWouldFail.count == 6)
        #expect(executable.count + adoptionWouldFail.count == offered.count)
    }
}
