import Foundation
import Testing

@testable import OpenFreshrCore

@Suite("UpdateBucket")
struct UpdateBucketTests {

    private func app(_ name: String = "Demo") -> InstalledApp {
        InstalledApp(
            bundlePath: "/Applications/\(name).app",
            bundleIdentifier: "com.example.\(name.lowercased())",
            shortVersion: "1.0",
            bundleVersion: "1"
        )
    }

    private let command = ResolvedCommand(executablePath: "/opt/homebrew/bin/brew", arguments: ["upgrade"])

    private func source(
        _ state: UpdateState, command: ResolvedCommand? = nil, blocker: UpdateActionBlocker? = nil
    ) -> SourceUpdate {
        SourceUpdate(
            appBundlePath: "/Applications/Demo.app", kind: .homebrew(token: "demo"), state: state,
            command: command, actionBlocker: blocker)
    }

    private func report(_ sources: [SourceUpdate], selfUpdating: Bool = false) -> AppUpdateReport {
        AppUpdateReport(app: app(), sources: sources, isSelfUpdating: selfUpdating)
    }

    private let newer = UpdateState.updateAvailable(available: "2.0", isMajor: false)

    @Test("A drivable update on an app that does not update itself is ready")
    func ready() {
        #expect(report([source(newer, command: command)]).bucket == .ready)
    }

    @Test("A newer version on a self-updating app is left to the app, even when OpenFreshr could drive it")
    func updatesItself() {
        #expect(report([source(newer, command: command)], selfUpdating: true).bucket == .updatesItself)
        #expect(report([source(newer)], selfUpdating: true).bucket == .updatesItself)
    }

    @Test("A newer version with no way to install it needs the person")
    func manual() {
        let noCommand = report([source(newer)])
        #expect(noCommand.bucket == .manual)
        #expect(noCommand.manualReason == .noAutomaticWay)
    }

    @Test("A predicted-to-fail take-over names Homebrew and the token as the reason")
    func manualReasonForBlockedTakeOver() {
        let blocked = report([source(newer, blocker: .adoptionWouldFail(caskToken: "demo"))])
        #expect(blocked.bucket == .manual)
        #expect(blocked.manualReason == .homebrewCannotTakeOver(caskToken: "demo"))
    }

    @Test("An app whose sources say it is current is up to date")
    func upToDate() {
        #expect(report([source(.upToDate)]).bucket == .upToDate)
    }

    @Test("Unknown is never up to date, and neither is an app with no source at all")
    func cannotTell() {
        #expect(report([source(.unknown(.noAvailableVersion))]).bucket == .cannotTell)
        #expect(report([]).bucket == .cannotTell)
    }

    @Test("One source that says current outweighs another that could not answer")
    func mixedAnswers() {
        #expect(report([source(.upToDate), source(.unknown(.feedUnreachable))]).bucket == .upToDate)
    }

    @Test("An update anywhere wins over an up-to-date answer elsewhere")
    func updateWins() {
        #expect(report([source(.upToDate), source(newer, command: command)]).bucket == .ready)
    }

    @Test("Buckets sort in the order a person cares about")
    func order() {
        #expect(UpdateBucket.allCases.sorted() == [.ready, .updatesItself, .manual, .cannotTell, .upToDate])
    }

    @Test("Only the manual bucket carries a reason")
    func reasonOnlyForManual() {
        #expect(report([source(.upToDate)]).manualReason == nil)
        #expect(report([source(newer, command: command)]).manualReason == nil)
    }
}
