import Foundation
import Testing
@testable import OpenFreshrCore

/// Behavioural tests for the update coordinator — the update-side analogue of
/// `AdoptionCoordinatorTests`. These prove the four contract points the spec
/// calls out by name: a self-updating Sparkle app is never auto-driven, a major
/// upgrade never shares a release with a regular one, one app's failure leaves
/// the others untouched, and success is only ever claimed after a rescan.
struct UpdateCoordinatorTests {

    // MARK: - Builders

    /// Assemble a coordinator. Each backend gets its own runner so a tool can be
    /// scripted or made absent independently; a tool is "present" only when its
    /// path is in `tools`.
    private func makeCoordinator(
        apps: [[InstalledApp]] = [[]],
        casks: [Cask] = [],
        tools: Set<Tool> = [],
        brewList: String = "",
        brewVersions: String = "",
        masOutdated: ProcessResult = .init(exitCode: 0, standardOutput: "", standardError: ""),
        msupdateList: ProcessResult = .init(exitCode: 0, standardOutput: "", standardError: ""),
        brewUpgrade: @escaping @Sendable ([String]) -> ProcessResult = { _ in .init(exitCode: 0, standardOutput: "ok", standardError: "") },
        fetcher: any HTTPFetching = FakeHTTPFetcher()
    ) -> UpdateCoordinator {
        var fs = FakeFileSystem()
        if tools.contains(.brew) { fs.addExistingPath("/opt/homebrew/bin/brew") }
        if tools.contains(.mas) { fs.addExistingPath("/opt/homebrew/bin/mas") }
        if tools.contains(.msupdate) { fs.addExistingPath(MicrosoftAutoUpdateBackend.defaultMsupdatePath) }

        let brewRunner = RecordingProcessRunner { _, args in
            if args == ["list", "--cask", "-1"] {
                return ProcessResult(exitCode: 0, standardOutput: brewList, standardError: "")
            }
            if args == ["list", "--cask", "--versions"] {
                return ProcessResult(exitCode: 0, standardOutput: brewVersions, standardError: "")
            }
            return brewUpgrade(args)
        }
        let masRunner = RecordingProcessRunner { _, args in
            args.first == "outdated" ? masOutdated : ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }
        let mauRunner = RecordingProcessRunner { _, args in
            args.first == "--list" ? msupdateList : ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }

        return UpdateCoordinator(
            scanner: ScriptedScanner(snapshots: apps),
            homebrew: HomebrewBackend(processRunner: brewRunner, fileSystem: fs),
            macAppStore: MacAppStoreBackend(processRunner: masRunner, fileSystem: fs),
            microsoftAutoUpdate: MicrosoftAutoUpdateBackend(processRunner: mauRunner, fileSystem: fs),
            catalog: CaskCatalog(casks: casks, fetchedAt: Date()),
            httpFetcher: fetcher,
            scanDirectories: ["/Applications"]
        )
    }

    private enum Tool: Hashable { case brew, mas, msupdate }

    private func report(_ reports: [AppUpdateReport], named bundleName: String) throws -> AppUpdateReport {
        try #require(reports.first { $0.app.bundleName == bundleName }, "missing \(bundleName)")
    }

    // MARK: - Homebrew detection

    @Test
    func homebrewUpdateIsDetectedDrivableAndBatchSelectable() async throws {
        let figma = InstalledApp(bundlePath: "/Applications/Figma.app",
                                 bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.3")
        let coordinator = makeCoordinator(
            apps: [[figma]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            tools: [.brew],
            brewList: "figma\n"
        )

        let reports = await coordinator.makeUpdateReports()
        let report = try report(reports, named: "Figma.app")

        let source = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(source.state == .updateAvailable(available: "1.2.4", isMajor: false))
        #expect(source.isDrivable)
        #expect(report.hasUpdate)
        #expect(report.isDefaultBatchSelectable)
        #expect(report.isSelfUpdating == false)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.targetVersion == "1.2.4")
        #expect(item.backend == .homebrew)
        #expect(item.command.arguments == ["upgrade", "--cask", "--greedy", "--", "figma"])
    }

    // MARK: - Receipt drift (the auto_updates blind spot)

    @Test
    func receiptDriftDrivesReinstallNotUpgrade() async throws {
        // The Transnomino shape: disk 9.5.1 trails cask 10.1.0, but the receipt was
        // already written to 10.1.0 (Homebrew skips the version check for
        // auto_updates casks). `brew upgrade` would compare receipt to cask, see a
        // match and no-op — so the effective command must be `reinstall`, which
        // actually re-lays the app onto the disk.
        let app = InstalledApp(bundlePath: "/Applications/Transnomino.app",
                               bundleIdentifier: "com.transnomino.app", shortVersion: "9.5.1")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "transnomino", names: ["Transnomino"], version: "10.1.0", autoUpdates: true)],
            tools: [.brew],
            brewList: "transnomino\n",
            brewVersions: "transnomino 10.1.0\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Transnomino.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })
        // Disk stays the sole authority on *whether* an update is due …
        #expect(source.state == .updateAvailable(available: "10.1.0", isMajor: true))
        #expect(source.state.hasUpdate)
        // … and the receipt-caught-up-but-disk-behind shape is named as drift.
        #expect(source.isReceiptDrift)
        #expect(source.isDrivable)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.homebrewStrategy == .reinstall)
        #expect(item.command.arguments == ["reinstall", "--cask", "--", "transnomino"])
    }

    @Test
    func aReceiptBehindTheCaskIsAnOrdinaryBacklogAndUpgrades() async throws {
        // The receipt trails the cask exactly like the disk does: a plain backlog,
        // where `brew upgrade` is the correct verb. The receipt reaching the cask
        // is what distinguishes drift, so this must NOT be a reinstall.
        let app = InstalledApp(bundlePath: "/Applications/Figma.app",
                               bundleIdentifier: "com.figma.Desktop", shortVersion: "1.0.0")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            tools: [.brew],
            brewList: "figma\n",
            brewVersions: "figma 1.0.0\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Figma.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(source.state.hasUpdate)
        #expect(source.isReceiptDrift == false)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.homebrewStrategy == .upgrade)
        #expect(item.command.arguments == ["upgrade", "--cask", "--greedy", "--", "figma"])
    }

    @Test
    func libreOfficeFinerDiskVersionIsNotReceiptDrift() async throws {
        // Receipt 26.8.0, disk 26.8.0.3, cask 26.8.0. The disk is merely *more*
        // finely versioned than the cask — it is not behind, so there is no update
        // and emphatically no reinstall. This is the false-alarm the spec calls out
        // by name: a finer disk version must never be mistaken for drift.
        let app = InstalledApp(bundlePath: "/Applications/LibreOffice.app",
                               bundleIdentifier: "org.libreoffice.script", shortVersion: "26.8.0.3")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "libreoffice", names: ["LibreOffice"], version: "26.8.0", autoUpdates: true)],
            tools: [.brew],
            brewList: "libreoffice\n",
            brewVersions: "libreoffice 26.8.0\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "LibreOffice.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(source.state.hasUpdate == false)
        #expect(source.isReceiptDrift == false)
        #expect(source.command == nil)
        #expect(report.hasUpdate == false)
    }

    @Test
    func anIncomparableReceiptIsNeverTreatedAsDrift() async throws {
        // Disk 1.0.0 genuinely trails cask 1.2.4 (a real update), but the receipt
        // carries an unparseable qualifier the comparator refuses. "Im Zweifel
        // nicht handeln": an inconclusive receipt cannot prove it reached the cask,
        // so this falls back to a plain upgrade rather than a reinstall.
        let app = InstalledApp(bundlePath: "/Applications/Thing.app",
                               bundleIdentifier: "com.thing.App", shortVersion: "1.0.0")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "thing", names: ["Thing"], version: "1.2.4")],
            tools: [.brew],
            brewList: "thing\n",
            brewVersions: "thing 1.2.4-mystery-build\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Thing.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(source.state.hasUpdate)
        #expect(source.isReceiptDrift == false)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.homebrewStrategy == .upgrade)
    }

    @Test
    func aReceiptDriftItemExecutesReinstallNotUpgrade() {
        // Execution counterpart: a drift item must run `brew reinstall`, and the
        // no-op `brew upgrade` must never appear. The rescan then confirms the disk.
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Transnomino.app",
                                 bundleIdentifier: "com.transnomino.app", shortVersion: "10.1.0")]],
            casks: [Cask(token: "transnomino", names: ["Transnomino"], version: "10.1.0", autoUpdates: true)],
            tools: [.brew],
            brewList: "transnomino\n",
            brewVersions: "transnomino 10.1.0\n",
            brewUpgrade: { args in
                log.record(args)
                return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
            }
        )

        let driftItem = Self.homebrewItem(
            bundlePath: "/Applications/Transnomino.app", name: "Transnomino.app",
            token: "transnomino", target: "10.1.0", isMajor: true, strategy: .reinstall
        )
        let outcome = coordinator.perform(driftItem)

        #expect(outcome.didUpdate)
        #expect(log.reinstallCalls == [["reinstall", "--cask", "--", "transnomino"]])
        #expect(log.upgradeCalls.isEmpty, "a drift item must never fall back to the no-op upgrade")
    }

    @Test
    func anUnmanagedDriftLikeItemIsRefusedNeitherUpgradeNorReinstall() {
        // The adoption guard from the previous fix still dominates: an unmanaged
        // cask is refused before the backend, so it gets neither upgrade nor
        // reinstall even when the item claims a reinstall strategy.
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Transnomino.app",
                                 bundleIdentifier: "com.transnomino.app", shortVersion: "9.5.1")]],
            casks: [Cask(token: "transnomino", names: ["Transnomino"], version: "10.1.0", autoUpdates: true)],
            tools: [.brew],
            brewList: "", // NOT managed
            brewUpgrade: { args in
                log.record(args)
                return ProcessResult(exitCode: 99, standardOutput: "", standardError: "MUST-NOT-RUN")
            }
        )

        let driftItem = Self.homebrewItem(
            bundlePath: "/Applications/Transnomino.app", name: "Transnomino.app",
            token: "transnomino", target: "10.1.0", isMajor: true, strategy: .reinstall
        )
        let outcome = coordinator.perform(driftItem)

        if case let .failed(_, reason) = outcome {
            #expect(reason == .requiresAdoption(caskToken: "transnomino"))
        } else {
            Issue.record("expected .failed(.requiresAdoption), got \(outcome)")
        }
        #expect(outcome.didUpdate == false)
        #expect(log.reinstallCalls.isEmpty, "brew reinstall must never run for an unmanaged cask")
        #expect(log.upgradeCalls.isEmpty, "brew upgrade must never run for an unmanaged cask")
    }

    @Test
    func referenceDatasetDriftMetricsAndCommands() async throws {
        // The three verified reference shapes side by side, so the drift count and
        // the per-app command are one reproducible number:
        //   transnomino  disk 9.5.1     cask 10.1.0    receipt 10.1.0   → reinstall
        //   whatsapp     disk 26.33.19  cask 26.34.24  receipt 26.34.24 → reinstall
        //   libreoffice  disk 26.8.0.3  cask 26.8.0    receipt 26.8.0   → nothing
        let apps = [
            InstalledApp(bundlePath: "/Applications/Transnomino.app",
                         bundleIdentifier: "com.transnomino.app", shortVersion: "9.5.1"),
            InstalledApp(bundlePath: "/Applications/WhatsApp.app",
                         bundleIdentifier: "net.whatsapp.WhatsApp", shortVersion: "26.33.19"),
            InstalledApp(bundlePath: "/Applications/LibreOffice.app",
                         bundleIdentifier: "org.libreoffice.script", shortVersion: "26.8.0.3"),
        ]
        let coordinator = makeCoordinator(
            apps: [apps],
            casks: [
                Cask(token: "transnomino", names: ["Transnomino"], version: "10.1.0", autoUpdates: true),
                Cask(token: "whatsapp", names: ["WhatsApp"], version: "26.34.24", autoUpdates: true),
                Cask(token: "libreoffice", names: ["LibreOffice"], version: "26.8.0", autoUpdates: true),
            ],
            tools: [.brew],
            brewList: "transnomino\nwhatsapp\nlibreoffice\n",
            brewVersions: "transnomino 10.1.0\nwhatsapp 26.34.24\nlibreoffice 26.8.0\n"
        )

        let reports = await coordinator.makeUpdateReports()
        func strategy(_ name: String) throws -> HomebrewUpdateStrategy? {
            let report = try report(reports, named: name)
            guard let source = report.sources.first(where: { $0.backend == .homebrew }),
                  let item = UpdateCoordinator.updateItem(for: report, source: source) else { return nil }
            return item.homebrewStrategy
        }

        let transnomino = try strategy("Transnomino.app")
        let whatsapp = try strategy("WhatsApp.app")
        let libreoffice = try strategy("LibreOffice.app")

        #expect(transnomino == .reinstall)
        #expect(whatsapp == .reinstall)
        #expect(libreoffice == nil) // up to date → no drivable item at all

        let drift = [("transnomino", transnomino), ("whatsapp", whatsapp), ("libreoffice", libreoffice)]
            .filter { $0.1 == .reinstall }
        print("[receipt-drift] drift=\(drift.count)/3 reinstall=\(drift.map(\.0)) "
            + "libreoffice=\(libreoffice.map(String.init(describing:)) ?? "none")")
        #expect(drift.count == 2)
    }

    @Test
    func incomparableHomebrewVersionsAreUnknownNeverAnUpdate() async throws {
        // Installed carries a pre-release qualifier on a marketing tie: the
        // comparator declines, so this must be `unbekannt`, not an update.
        let app = InstalledApp(bundlePath: "/Applications/Thing.app",
                               bundleIdentifier: "com.thing.App", shortVersion: "1.2.3-beta")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "thing", names: ["Thing"], version: "1.2.3")],
            tools: [.brew],
            brewList: "thing\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Thing.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(source.state.isUnknown)
        #expect(source.state.hasUpdate == false)
        #expect(report.hasUpdate == false)
        #expect(source.command == nil)
    }

    @Test
    func aConfidentlyUpToDateHomebrewAppOffersNothing() async throws {
        // The real `alfred` shape: installed "5.7.3" vs cask "5.7.3,2320" is up to
        // date, and a revision on one side alone must not manufacture an update.
        let app = InstalledApp(bundlePath: "/Applications/Alfred.app",
                               bundleIdentifier: "com.runningwithcrayons.Alfred", shortVersion: "5.7.3")
        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "alfred", names: ["Alfred"], version: "5.7.3,2320")],
            tools: [.brew],
            brewList: "alfred\n"
        )
        let report = try report(await coordinator.makeUpdateReports(), named: "Alfred.app")
        #expect(report.hasUpdate == false)
        #expect(report.sources.first { $0.backend == .homebrew }?.state == .upToDate)
    }

    // MARK: - Sparkle is display-only

    @Test
    func sparkleAppIsNeverAutoDrivenAndCarriesNoCommand() async throws {
        let feed = "https://example.com/appcast.xml"
        let app = InstalledApp(bundlePath: "/Applications/Sparkly.app",
                               bundleIdentifier: "com.example.Sparkly", shortVersion: "1.0",
                               sparkleFeedURL: feed)
        let fetcher = FakeHTTPFetcher()
        fetcher.setBody("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString></item>
        </channel></rss>
        """, for: feed)

        let coordinator = makeCoordinator(apps: [[app]], fetcher: fetcher)
        let report = try report(await coordinator.makeUpdateReports(), named: "Sparkly.app")

        let sparkle = try #require(report.sources.first { $0.kind.backend == nil })
        // An update is *shown* …
        #expect(sparkle.state == .updateAvailable(available: "2.0", isMajor: true))
        // … but it can never be driven: no backend, no command, not batch-eligible.
        #expect(sparkle.command == nil)
        #expect(sparkle.isDrivable == false)
        #expect(report.isSelfUpdating)
        #expect(report.isDefaultBatchSelectable == false)
        #expect(UpdateCoordinator.updateItem(for: report, source: sparkle) == nil)
    }

    @Test
    func aSelfUpdatingAppWithACaskIsWithheldFromTheDefaultBatchYetCanBeOptedIn() async throws {
        // Same app carries both a Sparkle feed *and* a Homebrew cask. The Homebrew
        // source is drivable, so the user may opt in per app — but because the app
        // self-updates, it stays out of the *default* batch selection.
        let feed = "https://example.com/appcast.xml"
        let app = InstalledApp(bundlePath: "/Applications/Dual.app",
                               bundleIdentifier: "com.example.Dual", shortVersion: "1.0",
                               sparkleFeedURL: feed)
        let fetcher = FakeHTTPFetcher()
        fetcher.setFailure("offline", for: feed) // feed state is irrelevant to the point

        let coordinator = makeCoordinator(
            apps: [[app]],
            casks: [Cask(token: "dual", names: ["Dual"], version: "1.1")],
            tools: [.brew],
            brewList: "dual\n",
            fetcher: fetcher
        )
        let report = try report(await coordinator.makeUpdateReports(), named: "Dual.app")

        let homebrew = try #require(report.sources.first { $0.backend == .homebrew })
        #expect(homebrew.isDrivable)                                   // opt-in is possible
        #expect(UpdateCoordinator.updateItem(for: report, source: homebrew) != nil)
        #expect(report.isSelfUpdating)
        #expect(report.isDefaultBatchSelectable == false)             // but not by default
    }

    @Test
    func sparkleFeedProbingIsConcurrencyLimited() async {
        let apps = (0..<20).map { index in
            InstalledApp(
                bundlePath: "/Applications/Sparkly \(index).app",
                bundleIdentifier: "com.example.sparkly\(index)",
                shortVersion: "1.0",
                sparkleFeedURL: "https://example.com/appcast-\(index).xml"
            )
        }
        let fetcher = ConcurrencyTrackingHTTPFetcher()
        let coordinator = makeCoordinator(apps: [apps], fetcher: fetcher)

        let reports = await coordinator.makeUpdateReports()

        #expect(reports.count == apps.count)
        #expect(fetcher.requestCount == apps.count)
        #expect(fetcher.maxConcurrentRequests <= 8)
    }

    // MARK: - Mac App Store & Microsoft AutoUpdate detection

    @Test
    func macAppStoreOutdatedEntryBecomesADrivableUpdate() async throws {
        let app = InstalledApp(bundlePath: "/Applications/Xcode.app",
                               bundleIdentifier: "com.apple.dt.Xcode", shortVersion: "14.0",
                               hasMacAppStoreReceipt: true)
        let coordinator = makeCoordinator(
            apps: [[app]],
            tools: [.mas],
            masOutdated: .init(exitCode: 0, standardOutput: "497799835 Xcode (14.0 -> 14.1)\n", standardError: "")
        )
        let report = try report(await coordinator.makeUpdateReports(), named: "Xcode.app")
        let source = try #require(report.sources.first { $0.backend == .macAppStore })
        #expect(source.state == .updateAvailable(available: "14.1", isMajor: false))
        #expect(source.isDrivable)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.command.arguments == ["upgrade", "497799835"])
    }

    @Test
    func macAppStoreDegradesToUnknownWhenMasIsAbsent() async throws {
        let app = InstalledApp(bundlePath: "/Applications/Xcode.app",
                               bundleIdentifier: "com.apple.dt.Xcode", shortVersion: "14.0",
                               hasMacAppStoreReceipt: true)
        let coordinator = makeCoordinator(apps: [[app]], tools: [])
        let report = try report(await coordinator.makeUpdateReports(), named: "Xcode.app")
        let source = try #require(report.sources.first { $0.backend == .macAppStore })
        #expect(source.state == .unknown(.toolUnavailable))
        #expect(report.hasSourceProblem)
    }

    @Test
    func microsoftAutoUpdateEntryBecomesADrivableUpdateAndIsBatchSelectable() async throws {
        let app = InstalledApp(bundlePath: "/Applications/Microsoft Word.app",
                               bundleIdentifier: "com.microsoft.Word", shortVersion: "16.77")
        let coordinator = makeCoordinator(
            apps: [[app]],
            tools: [.msupdate],
            msupdateList: .init(exitCode: 0, standardOutput: "Microsoft Word (MSWD2019) 16.78\n", standardError: "")
        )
        let report = try report(await coordinator.makeUpdateReports(), named: "Microsoft Word.app")
        let source = try #require(report.sources.first { $0.backend == .microsoftAutoUpdate })
        #expect(source.state == .updateAvailable(available: "16.78", isMajor: false))
        #expect(source.isDrivable)
        // MAU is the one self-updater OpenFreshr is allowed to drive by default.
        #expect(report.isDefaultBatchSelectable)

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        #expect(item.command.arguments == ["--install", "--apps", "MSWD2019"])
    }

    @Test
    func microsoftAutoUpdateStaysUnknownWhenTheListedVersionCannotBeParsed() async throws {
        // Listed but without a parseable version: conservative → unbekannt, never
        // an invented update.
        let app = InstalledApp(bundlePath: "/Applications/Microsoft Word.app",
                               bundleIdentifier: "com.microsoft.Word", shortVersion: "16.77")
        let coordinator = makeCoordinator(
            apps: [[app]],
            tools: [.msupdate],
            msupdateList: .init(exitCode: 0, standardOutput: "Microsoft Word (MSWD2019) up to date\n", standardError: "")
        )
        let report = try report(await coordinator.makeUpdateReports(), named: "Microsoft Word.app")
        let source = try #require(report.sources.first { $0.backend == .microsoftAutoUpdate })
        #expect(source.state.isUnknown)
        #expect(source.state.hasUpdate == false)
    }

    // MARK: - Major upgrades are never released with regular ones

    @Test
    func aMajorUpgradeNeverSharesAReleaseWithARegularOne() async throws {
        let regular = InstalledApp(bundlePath: "/Applications/Figma.app",
                                   bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.3")
        let major = InstalledApp(bundlePath: "/Applications/Bigapp.app",
                                 bundleIdentifier: "com.example.Bigapp", shortVersion: "1.9.9")
        let coordinator = makeCoordinator(
            apps: [[regular, major]],
            casks: [
                Cask(token: "figma", names: ["Figma"], version: "1.2.4"),
                Cask(token: "bigapp", names: ["Bigapp"], version: "2.0.0"),
            ],
            tools: [.brew],
            brewList: "figma\nbigapp\n"
        )
        let reports = await coordinator.makeUpdateReports()

        let regularReport = try report(reports, named: "Figma.app")
        let majorReport = try report(reports, named: "Bigapp.app")
        let regularSource = try #require(regularReport.sources.first { $0.backend == .homebrew })
        let majorSource = try #require(majorReport.sources.first { $0.backend == .homebrew })

        #expect(regularSource.state.isMajor == false)
        #expect(majorSource.state.isMajor == true)
        #expect(majorReport.hasMajorUpdate)

        let regularItem = try #require(UpdateCoordinator.updateItem(for: regularReport, source: regularSource))
        let majorItem = try #require(UpdateCoordinator.updateItem(for: majorReport, source: majorSource))

        // The structural guarantee: a mixed set cannot even be constructed.
        #expect(UpdateRelease(items: [regularItem, majorItem]) == nil)
        // Each pure set is fine.
        #expect(UpdateRelease(items: [regularItem])?.isMajor == false)
        #expect(UpdateRelease(items: [majorItem])?.isMajor == true)
    }

    // MARK: - Execution: isolation and rescan-confirmation

    @Test
    func aFailedUpdateLeavesTheOthersUntouchedAndConfirmsTheRestByRescan() async throws {
        // figma upgrades cleanly; slack's process fails. The post-update disk shows
        // figma at its new version and slack unchanged.
        let coordinator = makeCoordinator(
            apps: [[
                InstalledApp(bundlePath: "/Applications/Figma.app", bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.4"),
                InstalledApp(bundlePath: "/Applications/Slack.app", bundleIdentifier: "com.tinyspeck.slackmacgap", shortVersion: "3.0"),
            ]],
            casks: [
                Cask(token: "figma", names: ["Figma"], version: "1.2.4"),
                Cask(token: "slack", names: ["Slack"], version: "3.1"),
            ],
            tools: [.brew],
            brewList: "figma\nslack\n",
            brewUpgrade: { args in
                if args.contains("slack") {
                    return ProcessResult(exitCode: 1, standardOutput: "", standardError: "network down")
                }
                return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
            }
        )

        let figmaItem = Self.homebrewItem(bundlePath: "/Applications/Figma.app", name: "Figma.app", token: "figma", target: "1.2.4")
        let slackItem = Self.homebrewItem(bundlePath: "/Applications/Slack.app", name: "Slack.app", token: "slack", target: "3.1")
        let release = try #require(UpdateRelease(items: [figmaItem, slackItem]))

        let result = await coordinator.perform(release)

        #expect(result.updatedItems.map(\.app.bundleName) == ["Figma.app"])
        #expect(result.retryableItems.map(\.app.bundleName) == ["Slack.app"])
        #expect(result.allSucceeded == false)
        // The retry bundle contains only the app that did not land.
        #expect(result.retryRelease()?.items.map(\.app.bundleName) == ["Slack.app"])
    }

    @Test
    func backendSuccessIsNotTrustedWhenTheRescanStillSeesTheUpdate() async throws {
        // The backend "succeeds", but the rescan still shows the old version — so
        // success is refused. This is the "never optimistic" rule.
        let coordinator = makeCoordinator(
            apps: [[
                InstalledApp(bundlePath: "/Applications/Figma.app", bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.3"),
            ]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            tools: [.brew],
            brewList: "figma\n",
            brewUpgrade: { _ in ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "") }
        )
        let item = Self.homebrewItem(bundlePath: "/Applications/Figma.app", name: "Figma.app", token: "figma", target: "1.2.4")
        let outcome = coordinator.perform(item)

        #expect(outcome.didUpdate == false)
        #expect(outcome.isRetryable)
        if case .notConfirmedByRescan = outcome {} else {
            Issue.record("expected .notConfirmedByRescan, got \(outcome)")
        }
    }

    @Test
    func aConfirmedUpdateIsReportedOnlyAfterTheRescanAgrees() async throws {
        let coordinator = makeCoordinator(
            apps: [[
                InstalledApp(bundlePath: "/Applications/Figma.app", bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.4"),
            ]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            tools: [.brew],
            brewList: "figma\n"
        )
        let item = Self.homebrewItem(bundlePath: "/Applications/Figma.app", name: "Figma.app", token: "figma", target: "1.2.4")
        let outcome = coordinator.perform(item)
        #expect(outcome.didUpdate)
    }

    // MARK: - Adoptable-but-not-managed must never drive an upgrade (Amazon Photos)
    //
    // The reported regression: a user pressed "Major-Upgrade durchführen" for
    // Amazon Photos — an app confidently attributed to a cask, with a real newer
    // version — and `brew upgrade --cask --greedy -- amazon-photos` failed with
    // *"Cask 'amazon-photos' is not installed"*, because the cask was only
    // *adoptable*, never *brew-managed*. "A newer version exists" and "OpenFreshr
    // can run it" are different facts; these tests pin the distinction.

    @Test
    func amazonPhotosAdoptableButUnmanagedReportsUpdateWithoutADrivableCommand() async throws {
        // Adoptable — a non-auto-updating cask with no rival identity stays
        // eligible (Homebrew's own version check guards a wrong match) — but the
        // token is NOT in `brew list --cask`, so it is not brew-managed.
        let amazonPhotos = InstalledApp(
            bundlePath: "/Applications/Amazon Photos.app",
            bundleIdentifier: "com.amazon.clouddrive.photos",
            shortVersion: "1.0.0",
            bundleVersion: "1.0.0"
        )
        let coordinator = makeCoordinator(
            apps: [[amazonPhotos]],
            casks: [Cask(
                token: "amazon-photos",
                names: ["Amazon Photos"],
                version: "2.0.0", // a major bump over 1.0.0 — the pressed path
                autoUpdates: false,
                artifacts: [CaskArtifact(kind: .app, target: "Amazon Photos.app")],
                primaryBundleIdentifiers: []
            )],
            tools: [.brew],
            brewList: "" // nothing managed — mirrors the reference system
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Amazon Photos.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })

        // The information is preserved and correct: a real, MAJOR update is known…
        #expect(source.state == .updateAvailable(available: "2.0.0", isMajor: true))
        #expect(report.hasUpdate)
        #expect(report.hasMajorUpdate)

        // …but the ACTION is withheld and explicitly named, never a command.
        #expect(source.command == nil)
        #expect(source.isDrivable == false)
        #expect(source.adoptionWouldFail)
        #expect(report.adoptionWouldFailForUpdate)
        #expect(source.actionBlocker == .adoptionWouldFail(caskToken: "amazon-photos"))

        // It never becomes a unit of work, nor a default batch pick.
        #expect(UpdateCoordinator.updateItem(for: report, source: source) == nil)
        #expect(report.isDefaultBatchSelectable == false)
    }

    @Test
    func anAdoptableButUnmanagedMajorUpgradeIsRefusedBeforeReachingTheBackend() async {
        // The exact failing path: a MAJOR item is handed to the coordinator for an
        // unmanaged cask. The execution-site guard must refuse it BEFORE `brew`
        // runs — `brewUpgrade` is wired to a sentinel that must never be called.
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Amazon Photos.app",
                                 bundleIdentifier: "com.amazon.clouddrive.photos", shortVersion: "1.0.0")]],
            casks: [Cask(token: "amazon-photos", names: ["Amazon Photos"], version: "2.0.0", autoUpdates: false)],
            tools: [.brew],
            brewList: "", // amazon-photos is NOT managed
            brewUpgrade: { args in
                log.record(args)
                return ProcessResult(exitCode: 99, standardOutput: "", standardError: "MUST-NOT-RUN")
            }
        )

        let majorItem = Self.homebrewItem(
            bundlePath: "/Applications/Amazon Photos.app", name: "Amazon Photos.app",
            token: "amazon-photos", target: "2.0.0", isMajor: true
        )
        let outcome = coordinator.perform(majorItem)

        // Refused with the adoption reason — the backend was never invoked.
        if case let .failed(_, reason) = outcome {
            #expect(reason == .requiresAdoption(caskToken: "amazon-photos"))
        } else {
            Issue.record("expected .failed(.requiresAdoption), got \(outcome)")
        }
        #expect(outcome.didUpdate == false)
        #expect(log.upgradeCalls.isEmpty, "brew upgrade must never run for an unmanaged cask")
    }

    @Test
    func aManagedMajorUpgradeStillReachesTheBackendAndIsExecuted() {
        // Counter-proof: the very same MAJOR item, but now the cask IS brew-managed.
        // The guard lets it through, the backend runs, and the rescan confirms it.
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Figma.app",
                                 bundleIdentifier: "com.figma.Desktop", shortVersion: "2.0.0")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "2.0.0")],
            tools: [.brew],
            brewList: "figma\n", // managed → drivable
            brewUpgrade: { args in
                log.record(args)
                return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
            }
        )

        let majorItem = Self.homebrewItem(
            bundlePath: "/Applications/Figma.app", name: "Figma.app",
            token: "figma", target: "2.0.0", isMajor: true
        )
        let outcome = coordinator.perform(majorItem)

        #expect(outcome.didUpdate)
        #expect(log.upgradeCalls == [["upgrade", "--cask", "--greedy", "--", "figma"]])
    }

    // MARK: - Merged adopt-then-update (the unmanaged app's "Aktualisieren")

    @Test
    func anUnmanagedButAdoptableAppWithAnUpdateRunsAdoptThenReinstallInOrder() async throws {
        // The reported fix. A manually-installed app that Homebrew does NOT manage,
        // whose cask auto-updates, becomes a single drivable "Aktualisieren". The
        // plan is two commands — `install --cask --adopt` then `reinstall --cask` —
        // that must run in that order, and only a rescan confirms the disk landed.
        let widget = InstalledApp(
            bundlePath: "/Applications/Widget.app", bundleIdentifier: "com.example.widget",
            shortVersion: "1.0.0", bundleVersion: "1.0.0"
        )
        let widgetUpdated = InstalledApp(
            bundlePath: "/Applications/Widget.app", bundleIdentifier: "com.example.widget",
            shortVersion: "1.1.0", bundleVersion: "1.1.0"
        )
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[widget], [widgetUpdated]], // scan #1 reports; scan #2 confirms
            casks: [Cask(
                token: "widget", names: ["Widget"], version: "1.1.0", autoUpdates: true,
                artifacts: [CaskArtifact(kind: .app, target: "Widget.app")],
                primaryBundleIdentifiers: ["com.example.widget"]
            )],
            tools: [.brew],
            brewList: "", // NOT managed — the whole point
            brewUpgrade: { args in
                log.record(args)
                return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
            }
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Widget.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })

        // One user action, two previewed commands in order — and it IS drivable.
        #expect(source.state == .updateAvailable(available: "1.1.0", isMajor: false))
        #expect(source.isDrivable)
        #expect(source.adoptionWouldFail == false)
        #expect(source.homebrewStrategy == .adoptThenReinstall)
        #expect(source.commandPlan.map(\.arguments) == [
            ["install", "--cask", "--adopt", "--", "widget"],
            ["reinstall", "--cask", "--", "widget"],
        ])

        let item = try #require(UpdateCoordinator.updateItem(for: report, source: source))
        let outcome = coordinator.perform(item)

        #expect(outcome.didUpdate)
        #expect(log.allCalls == [
            ["install", "--cask", "--adopt", "--", "widget"],
            ["reinstall", "--cask", "--", "widget"],
        ])
        #expect(log.allCalls.allSatisfy { !$0.contains("--force") },
                "the adopt-then-update chain must never pass --force")
    }

    @Test
    func whenTheAdoptStepFailsTheReinstallIsNeverRun() {
        // Step 1 gates step 2. If `install --cask --adopt` aborts (Homebrew's
        // version-mismatch CaskError), the reinstall must not run and the error is
        // attributed to this app — never a false success.
        let log = CallLog()
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Widget.app",
                                 bundleIdentifier: "com.example.widget", shortVersion: "1.0.0")]],
            casks: [Cask(token: "widget", names: ["Widget"], version: "1.1.0", autoUpdates: true)],
            tools: [.brew],
            brewList: "",
            brewUpgrade: { args in
                log.record(args)
                if args.first == "install" {
                    return ProcessResult(exitCode: 1, standardOutput: "",
                                         standardError: "Error: CaskError: version mismatch, refusing to adopt")
                }
                return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
            }
        )

        let item = Self.homebrewItem(
            bundlePath: "/Applications/Widget.app", name: "Widget.app",
            token: "widget", target: "1.1.0", strategy: .adoptThenReinstall
        )
        let outcome = coordinator.perform(item)

        // The adopt ran and failed; the reinstall was skipped.
        #expect(log.installCalls == [["install", "--cask", "--adopt", "--", "widget"]])
        #expect(log.reinstallCalls.isEmpty, "step 2 must not run after a failed adopt")
        #expect(outcome.didUpdate == false)
        if case .caskError = outcome {} else {
            Issue.record("expected .caskError from a refused adopt, got \(outcome)")
        }
    }

    @Test
    func aManagedAppWithAnUpdateStillProducesExactlyOneCommand() async throws {
        // Counter-proof: an app Homebrew already manages keeps the single-step
        // upgrade — the merge adds a second command only for unmanaged apps.
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Figma.app",
                                 bundleIdentifier: "com.figma.Desktop", shortVersion: "1.2.3")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            tools: [.brew],
            brewList: "figma\n"
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Figma.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })

        #expect(source.homebrewStrategy == .upgrade)
        #expect(source.commandPlan.map(\.arguments) == [["upgrade", "--cask", "--greedy", "--", "figma"]])
    }

    @Test
    func anAdoptionPredictedToFailIsNeverBuiltIntoAnExecutableCommand() async throws {
        // `auto_updates == false` with a version mismatch is Homebrew's guarded
        // refusal. The prediction logic flags it up-front: the update stays visible
        // and honestly named, but no command is attached and nothing can run.
        let coordinator = makeCoordinator(
            apps: [[InstalledApp(bundlePath: "/Applications/Amazon Photos.app",
                                 bundleIdentifier: "com.amazon.clouddrive.photos",
                                 shortVersion: "1.0.0", bundleVersion: "1.0.0")]],
            casks: [Cask(
                token: "amazon-photos", names: ["Amazon Photos"], version: "2.0.0",
                autoUpdates: false,
                artifacts: [CaskArtifact(kind: .app, target: "Amazon Photos.app")],
                primaryBundleIdentifiers: []
            )],
            tools: [.brew],
            brewList: ""
        )

        let report = try report(await coordinator.makeUpdateReports(), named: "Amazon Photos.app")
        let source = try #require(report.sources.first { $0.backend == .homebrew })

        #expect(report.hasUpdate)
        #expect(source.adoptionWouldFail)
        #expect(source.command == nil)
        #expect(source.commandPlan.isEmpty)
        #expect(source.isDrivable == false)
        #expect(UpdateCoordinator.updateItem(for: report, source: source) == nil)
    }

    @Test
    func noHomebrewStrategyEverEmitsForce() {
        // A guard rail pinned as a test: `--force` is forbidden on every path, so
        // no strategy's command plan may contain it.
        for strategy in [HomebrewUpdateStrategy.upgrade, .reinstall, .adoptThenReinstall] {
            let flattened = HomebrewBackend.commandPlan(for: strategy, token: "widget").flatMap { $0 }
            #expect(!flattened.contains("--force"), "\(strategy) must not pass --force")
        }
    }

    private static func homebrewItem(
        bundlePath: String, name: String, token: String, target: String,
        isMajor: Bool = false, strategy: HomebrewUpdateStrategy = .upgrade
    ) -> UpdateItem {
        // Build the item's plan from the backend's single source of truth so the
        // previewed and executed commands match — one command for upgrade/reinstall,
        // two (adopt, then reinstall) for `.adoptThenReinstall`.
        let plan = HomebrewBackend.commandPlan(for: strategy, token: token).map {
            ResolvedCommand(executablePath: "/opt/homebrew/bin/brew", arguments: $0)
        }
        return UpdateItem(
            app: InstalledApp(bundlePath: bundlePath, shortVersion: nil),
            sourceKind: .homebrew(token: token),
            backend: .homebrew,
            command: plan[0],
            targetVersion: target,
            isMajor: isMajor,
            homebrewStrategy: strategy,
            commandPlan: plan
        )
    }
}

/// Records the argument vectors passed to the scripted `brew` upgrade closure, so
/// a test can prove the backend was (or was not) actually invoked. `brew list
/// --cask -1` is answered separately in `makeCoordinator`, so only real
/// upgrade/other invocations land here.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func record(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
    }

    /// Every recorded invocation that is a `brew upgrade`.
    var upgradeCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.first == "upgrade" }
    }

    /// Every recorded invocation that is a `brew reinstall` (the drift verb).
    var reinstallCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.first == "reinstall" }
    }

    /// Every recorded invocation that is a `brew install` (the adopt step runs
    /// `install --cask --adopt`).
    var installCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.first == "install" }
    }

    /// Every recorded invocation, in order — for asserting exact command sequences.
    var allCalls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

private final class ConcurrencyTrackingHTTPFetcher: HTTPFetching, @unchecked Sendable {

    private let lock = NSLock()
    private var activeRequests = 0
    private var observedMaxConcurrentRequests = 0
    private var observedRequestCount = 0

    var maxConcurrentRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return observedMaxConcurrentRequests
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observedRequestCount
    }

    func data(from url: URL) async throws -> Data {
        beginRequest()
        defer { endRequest() }

        try await Task.sleep(for: .milliseconds(20))
        return Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString></item>
        </channel></rss>
        """.utf8)
    }

    private func beginRequest() {
        lock.lock(); defer { lock.unlock() }
        activeRequests += 1
        observedRequestCount += 1
        observedMaxConcurrentRequests = max(observedMaxConcurrentRequests, activeRequests)
    }

    private func endRequest() {
        lock.lock(); defer { lock.unlock() }
        activeRequests -= 1
    }
}
