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
        masOutdated: ProcessResult = .init(exitCode: 0, standardOutput: "", standardError: ""),
        msupdateList: ProcessResult = .init(exitCode: 0, standardOutput: "", standardError: ""),
        brewUpgrade: @escaping @Sendable ([String]) -> ProcessResult = { _ in .init(exitCode: 0, standardOutput: "ok", standardError: "") },
        fetcher: FakeHTTPFetcher = FakeHTTPFetcher()
    ) -> UpdateCoordinator {
        var fs = FakeFileSystem()
        if tools.contains(.brew) { fs.addExistingPath("/opt/homebrew/bin/brew") }
        if tools.contains(.mas) { fs.addExistingPath("/opt/homebrew/bin/mas") }
        if tools.contains(.msupdate) { fs.addExistingPath(MicrosoftAutoUpdateBackend.defaultMsupdatePath) }

        let brewRunner = RecordingProcessRunner { _, args in
            if args == ["list", "--cask", "-1"] {
                return ProcessResult(exitCode: 0, standardOutput: brewList, standardError: "")
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
            tools: [.brew]
        )
        let item = Self.homebrewItem(bundlePath: "/Applications/Figma.app", name: "Figma.app", token: "figma", target: "1.2.4")
        let outcome = coordinator.perform(item)
        #expect(outcome.didUpdate)
    }

    private static func homebrewItem(
        bundlePath: String, name: String, token: String, target: String, isMajor: Bool = false
    ) -> UpdateItem {
        UpdateItem(
            app: InstalledApp(bundlePath: bundlePath, shortVersion: nil),
            sourceKind: .homebrew(token: token),
            backend: .homebrew,
            command: ResolvedCommand(executablePath: "/opt/homebrew/bin/brew",
                                     arguments: ["upgrade", "--cask", "--greedy", "--", token]),
            targetVersion: target,
            isMajor: isMajor
        )
    }
}
