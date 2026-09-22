import Foundation
import Testing

@testable import OpenFreshrCore

/// An ecosystem with programmed answers, so the coordinator is tested without any
/// tool. The list of outdated names shrinks when an update "works", which is what
/// lets the verification step be exercised both ways.
private final class FakeEcosystem: EcosystemUpdating, @unchecked Sendable {
    let kind: EcosystemKind
    private let lock = NSLock()
    private var outdated: [OutdatedPackage]
    private let available: Bool
    private let updateWorks: Bool
    private let reportsSuccess: Bool

    init(
        kind: EcosystemKind, outdated: [OutdatedPackage] = [], available: Bool = true,
        updateWorks: Bool = true, reportsSuccess: Bool = true
    ) {
        self.kind = kind
        self.outdated = outdated
        self.available = available
        self.updateWorks = updateWorks
        self.reportsSuccess = reportsSuccess
    }

    func isAvailable() -> Bool { available }

    func check() -> EcosystemCheck {
        lock.lock()
        defer { lock.unlock() }
        return outdated.isEmpty ? .upToDate : .outdated(outdated)
    }

    func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? { nil }

    func update(_ package: OutdatedPackage) -> BackendActionResult {
        lock.lock()
        defer { lock.unlock() }
        if updateWorks { outdated.removeAll { $0.name == package.name } }
        return reportsSuccess
            ? .succeeded(standardOutput: "")
            : .failed(reason: .processFailed(exitCode: 1, standardError: "no"))
    }
}

private func package(_ name: String, _ kind: EcosystemKind = .npm) -> OutdatedPackage {
    OutdatedPackage(ecosystem: kind, name: name, installed: "1.0.0", available: "1.1.0", isMajor: false)
}

@Suite("EcosystemCoordinator")
struct EcosystemCoordinatorTests {

    @Test("An unavailable tool is reported, not left out and not read as up to date")
    func unavailableIsReported() async {
        let coordinator = EcosystemCoordinator(ecosystems: [
            FakeEcosystem(kind: .npm, outdated: [package("left-pad")]),
            FakeEcosystem(kind: .pipx, available: false),
        ])
        let reports = await coordinator.checkAll()
        #expect(reports.map(\.kind) == [.npm, .pipx])
        #expect(reports[0].check.packages.map(\.name) == ["left-pad"])
        #expect(reports[1].check == .unavailable)
    }

    @Test("Reports keep the order the ecosystems were given")
    func order() async {
        let kinds: [EcosystemKind] = [.pipx, .homebrewFormula, .npm, .macOS]
        let coordinator = EcosystemCoordinator(ecosystems: kinds.map { FakeEcosystem(kind: $0) })
        #expect(await coordinator.checkAll().map(\.kind) == kinds)
    }

    @Test("A reported success is verified by a fresh check")
    func verifiedSuccess() async {
        let coordinator = EcosystemCoordinator(ecosystems: [
            FakeEcosystem(kind: .npm, outdated: [package("a"), package("b")])
        ])
        let results = await coordinator.update([package("a")])
        #expect(results.count == 1)
        #expect(results[0].stillOutdated == false)
        #expect(results[0].isVerified)
    }

    @Test("A tool that claims success but changed nothing is not verified")
    func claimedButNotDone() async {
        let coordinator = EcosystemCoordinator(ecosystems: [
            FakeEcosystem(kind: .npm, outdated: [package("a")], updateWorks: false)
        ])
        let results = await coordinator.update([package("a")])
        #expect(results[0].action.didReportSuccess)
        #expect(results[0].stillOutdated == true)
        #expect(!results[0].isVerified)
    }

    @Test("A failed update is not rechecked and not verified")
    func failure() async {
        let coordinator = EcosystemCoordinator(ecosystems: [
            FakeEcosystem(kind: .npm, outdated: [package("a")], reportsSuccess: false)
        ])
        let results = await coordinator.update([package("a")])
        #expect(results[0].stillOutdated == nil)
        #expect(!results[0].isVerified)
    }

    @Test("A package whose ecosystem is not configured fails without running anything")
    func unknownEcosystem() async {
        let coordinator = EcosystemCoordinator(ecosystems: [])
        let results = await coordinator.update([package("a")])
        #expect(!results[0].action.didReportSuccess)
    }
}

@Suite("HomebrewFormulaEcosystem")
struct HomebrewFormulaEcosystemTests {

    private let brew = "/opt/homebrew/bin/brew"

    private func ecosystem(
        brewInstalled: Bool = true,
        handler: @escaping @Sendable (URL, [String]) -> ProcessResult
    ) -> (HomebrewFormulaEcosystem, RecordingProcessRunner) {
        var fileSystem = FakeFileSystem()
        if brewInstalled { fileSystem.addExistingPath(brew) }
        let runner = RecordingProcessRunner(handler: handler)
        return (HomebrewFormulaEcosystem(processRunner: runner, fileSystem: fileSystem), runner)
    }

    private let sample = """
        {"formulae":[
          {"name":"git","installed_versions":["2.44.0"],"current_version":"2.45.1","pinned":false},
          {"name":"node@20","installed_versions":["20.1.0","20.2.0"],"current_version":"20.3.0","pinned":false},
          {"name":"held","installed_versions":["1.0"],"current_version":"2.0","pinned":true}
        ],"casks":[]}
        """

    @Test("It parses outdated formulae, uses the newest installed version and skips pinned ones")
    func parses() {
        let (ecosystem, runner) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: self.sample, standardError: "")
        }
        let packages = ecosystem.check().packages
        #expect(packages.map(\.name) == ["git", "node@20"])
        #expect(packages[1].installed == "20.2.0")
        #expect(packages[0].isMajor == false)
        #expect(runner.invocations.first?.arguments == ["outdated", "--formula", "--json=v2"])
    }

    @Test("A second, batched call fetches descriptions for every outdated formula and attaches them")
    func fetchesDescriptions() {
        let infoSample = """
            {"formulae":[
              {"name":"git","desc":"Distributed revision control system"},
              {"name":"node@20","desc":""}
            ]}
            """
        let (ecosystem, runner) = ecosystem { _, arguments in
            if arguments.first == "outdated" {
                return ProcessResult(exitCode: 0, standardOutput: self.sample, standardError: "")
            }
            return ProcessResult(exitCode: 0, standardOutput: infoSample, standardError: "")
        }
        let packages = ecosystem.check().packages
        #expect(packages.first(where: { $0.name == "git" })?.description == "Distributed revision control system")
        // An empty desc from brew is treated as no description, not a blank line.
        #expect(packages.first(where: { $0.name == "node@20" })?.description == nil)

        let infoCall = runner.invocations.last
        #expect(infoCall?.arguments == ["info", "--json=v2", "--formula", "--", "git", "node@20"])
    }

    @Test("A failed or unparsable info call never fails the check — packages stay outdated, just without a description")
    func descriptionFailureIsHarmless() {
        let (ecosystem, _) = ecosystem { _, arguments in
            if arguments.first == "outdated" {
                return ProcessResult(exitCode: 0, standardOutput: self.sample, standardError: "")
            }
            return ProcessResult(exitCode: 1, standardOutput: "", standardError: "boom")
        }
        let packages = ecosystem.check().packages
        #expect(packages.map(\.name) == ["git", "node@20"])
        #expect(packages.allSatisfy { $0.description == nil })
    }

    @Test("No outdated formulae is up to date")
    func upToDate() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: #"{"formulae":[],"casks":[]}"#, standardError: "")
        }
        #expect(ecosystem.check() == .upToDate)
    }

    @Test("Output that is not the expected JSON is unknown, never up to date")
    func garbage() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "Error: something", standardError: "")
        }
        #expect(ecosystem.check() == .unknown(.unparsableOutput))
    }

    @Test("A failing brew is unknown, never up to date")
    func failing() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "boom")
        }
        #expect(ecosystem.check() == .unknown(.processFailed(exitCode: 1, standardError: "boom")))
    }

    @Test("Without brew the ecosystem is unavailable and nothing runs")
    func noBrew() {
        let (ecosystem, runner) = ecosystem(brewInstalled: false) { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        #expect(!ecosystem.isAvailable())
        #expect(ecosystem.check() == .unavailable)
        #expect(runner.invocations.isEmpty)
    }

    @Test("The update command follows -- so a name can never be read as a flag")
    func command() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let git = OutdatedPackage(
            ecosystem: .homebrewFormula, name: "git", installed: "1", available: "2", isMajor: true)
        let command = ecosystem.resolveUpdateCommand(for: git)
        #expect(command?.executablePath == brew)
        #expect(command?.arguments == ["upgrade", "--formula", "--", "git"])
    }

    @Test("Names that could be parsed as flags or shell text are refused before any process runs")
    func rejectsHostileNames() {
        let (ecosystem, runner) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        for name in ["-v", "--appdir=/tmp/x", "a; rm -rf /", "Git", "", "git\n", "a/b/c/d", "../etc"] {
            let hostile = OutdatedPackage(
                ecosystem: .homebrewFormula, name: name, installed: "1", available: "2", isMajor: false)
            #expect(ecosystem.resolveUpdateCommand(for: hostile) == nil, "\(name)")
            #expect(!ecosystem.update(hostile).didReportSuccess, "\(name)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("Tap-qualified names are accepted")
    func tapNames() {
        #expect(HomebrewFormulaEcosystem.isValidFormulaName("user/tap/name"))
        #expect(HomebrewFormulaEcosystem.isValidFormulaName("openssl@3"))
    }
}

@Suite("NpmEcosystem")
struct NpmEcosystemTests {

    private let npm = "/opt/homebrew/bin/npm"

    private func ecosystem(
        npmInstalled: Bool = true,
        handler: @escaping @Sendable (URL, [String]) -> ProcessResult
    ) -> (NpmEcosystem, RecordingProcessRunner) {
        var fileSystem = FakeFileSystem()
        if npmInstalled { fileSystem.addExistingPath(npm) }
        let runner = RecordingProcessRunner(handler: handler)
        return (NpmEcosystem(processRunner: runner, fileSystem: fileSystem), runner)
    }

    private let sample = """
        {
          "corepack": {"current": "0.35.0", "wanted": "0.36.0", "latest": "0.36.0"},
          "typescript": {"current": "5.4.0", "wanted": "5.4.9", "latest": "5.6.0"}
        }
        """

    @Test("It parses outdated packages, exit code 1 included, and prefers latest over wanted")
    func parses() {
        let (ecosystem, runner) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: self.sample, standardError: "")
        }
        let packages = ecosystem.check().packages
        #expect(packages.map(\.name) == ["corepack", "typescript"])
        #expect(packages[1].available == "5.6.0")
        #expect(runner.invocations.first?.arguments == ["outdated", "--global", "--json"])
    }

    @Test("Empty object, exit 0, is up to date")
    func upToDate() {
        let (ecosystem, _) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "{}", standardError: "") }
        #expect(ecosystem.check() == .upToDate)
    }

    @Test("Blank output on exit 0 is also up to date")
    func blankOutput() {
        let (ecosystem, _) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "") }
        #expect(ecosystem.check() == .upToDate)
    }

    @Test("Exit 1 with stderr is a real failure, not \"outdated found\"")
    func exitOneWithStderrIsFailure() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "npm error network timeout")
        }
        #expect(ecosystem.check() == .unknown(.processFailed(exitCode: 1, standardError: "npm error network timeout")))
    }

    @Test("Output that is not the expected JSON is unknown, never up to date")
    func garbage() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "not json", standardError: "")
        }
        #expect(ecosystem.check() == .unknown(.unparsableOutput))
    }

    @Test("An entry with no installed version, e.g. a broken link, is skipped")
    func skipsEntryWithoutCurrent() {
        let json = #"{"ghost": {"wanted": "1.0.0", "latest": "1.0.0"}}"#
        #expect(NpmEcosystem.parseOutdated(json) == [])
    }

    @Test("Without npm the ecosystem is unavailable and nothing runs")
    func noNpm() {
        let (ecosystem, runner) = ecosystem(npmInstalled: false) { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        #expect(!ecosystem.isAvailable())
        #expect(ecosystem.check() == .unavailable)
        #expect(runner.invocations.isEmpty)
    }

    @Test("The update command targets @latest, unscoped and scoped alike")
    func command() {
        let (ecosystem, _) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "") }
        let plain = OutdatedPackage(
            ecosystem: .npm, name: "typescript", installed: "5.4", available: "5.6", isMajor: false)
        #expect(
            ecosystem.resolveUpdateCommand(for: plain)?.arguments == ["install", "--global", "--", "typescript@latest"])
        let scoped = OutdatedPackage(
            ecosystem: .npm, name: "@angular/cli", installed: "17", available: "18", isMajor: true)
        #expect(
            ecosystem.resolveUpdateCommand(for: scoped)?.arguments
                == ["install", "--global", "--", "@angular/cli@latest"])
    }

    @Test("Names that could be parsed as flags are refused before any process runs")
    func rejectsHostileNames() {
        let (ecosystem, runner) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        for name in ["-g", "--force", "a; rm -rf /", "UPPER", "", "left-pad\n", "@Scope/name"] {
            let hostile = OutdatedPackage(ecosystem: .npm, name: name, installed: "1", available: "2", isMajor: false)
            #expect(ecosystem.resolveUpdateCommand(for: hostile) == nil, "\(name)")
            #expect(!ecosystem.update(hostile).didReportSuccess, "\(name)")
        }
        #expect(runner.invocations.isEmpty)
    }
}

/// Verified directly against real `pnpm 10.33.3` (see ``PnpmEcosystem``'s doc
/// comment): `pnpm outdated -g --json` shares npm's exact JSON contract and
/// exit-code-1-means-outdated behaviour, so this suite mirrors
/// ``NpmEcosystemTests`` case for case.
@Suite("PnpmEcosystem")
struct PnpmEcosystemTests {

    private let pnpm = "/opt/homebrew/bin/pnpm"

    private func ecosystem(
        pnpmInstalled: Bool = true,
        handler: @escaping @Sendable (URL, [String]) -> ProcessResult
    ) -> (PnpmEcosystem, RecordingProcessRunner) {
        var fileSystem = FakeFileSystem()
        if pnpmInstalled { fileSystem.addExistingPath(pnpm) }
        let runner = RecordingProcessRunner(handler: handler)
        return (PnpmEcosystem(processRunner: runner, fileSystem: fileSystem), runner)
    }

    private let sample = """
        {
          "cowsay": {"current": "1.5.0", "wanted": "1.5.0", "latest": "1.6.0", "isDeprecated": false, "dependencyType": "dependencies"},
          "typescript": {"current": "5.4.0", "wanted": "5.4.9", "latest": "5.6.0"}
        }
        """

    @Test("It parses outdated packages, exit code 1 included, and prefers latest over wanted")
    func parses() {
        let (ecosystem, runner) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: self.sample, standardError: "")
        }
        let packages = ecosystem.check().packages
        #expect(packages.map(\.name) == ["cowsay", "typescript"])
        #expect(packages[0].available == "1.6.0")
        #expect(runner.invocations.first?.arguments == ["outdated", "--global", "--json"])
    }

    @Test("Empty object, exit 0, is up to date")
    func upToDate() {
        let (ecosystem, _) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "{}", standardError: "") }
        #expect(ecosystem.check() == .upToDate)
    }

    @Test("Exit 1 with stderr is a real failure, not \"outdated found\"")
    func exitOneWithStderrIsFailure() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "ERR_PNPM_FETCH_404")
        }
        #expect(ecosystem.check() == .unknown(.processFailed(exitCode: 1, standardError: "ERR_PNPM_FETCH_404")))
    }

    @Test("Output that is not the expected JSON is unknown, never up to date")
    func garbage() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "not json", standardError: "")
        }
        #expect(ecosystem.check() == .unknown(.unparsableOutput))
    }

    @Test("Without pnpm the ecosystem is unavailable and nothing runs")
    func noPnpm() {
        let (ecosystem, runner) = ecosystem(pnpmInstalled: false) { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        #expect(!ecosystem.isAvailable())
        #expect(ecosystem.check() == .unavailable)
        #expect(runner.invocations.isEmpty)
    }

    @Test("The update command targets @latest via `add`, unscoped and scoped alike")
    func command() {
        let (ecosystem, _) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "") }
        let plain = OutdatedPackage(
            ecosystem: .pnpm, name: "cowsay", installed: "1.5.0", available: "1.6.0", isMajor: false)
        #expect(
            ecosystem.resolveUpdateCommand(for: plain)?.arguments == ["add", "--global", "--", "cowsay@latest"])
        let scoped = OutdatedPackage(
            ecosystem: .pnpm, name: "@github/copilot", installed: "1.0.78", available: "1.0.87", isMajor: false)
        #expect(
            ecosystem.resolveUpdateCommand(for: scoped)?.arguments
                == ["add", "--global", "--", "@github/copilot@latest"])
    }

    @Test("Names that could be parsed as flags are refused before any process runs")
    func rejectsHostileNames() {
        let (ecosystem, runner) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        for name in ["-g", "--force", "a; rm -rf /", "UPPER", "", "left-pad\n", "@Scope/name"] {
            let hostile = OutdatedPackage(ecosystem: .pnpm, name: name, installed: "1", available: "2", isMajor: false)
            #expect(ecosystem.resolveUpdateCommand(for: hostile) == nil, "\(name)")
            #expect(!ecosystem.update(hostile).didReportSuccess, "\(name)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test("A package with the wrong ecosystem tag is refused, never routed to pnpm by name alone")
    func refusesWrongEcosystemTag() {
        let (ecosystem, runner) = ecosystem { _, _ in ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let npmTagged = OutdatedPackage(
            ecosystem: .npm, name: "cowsay", installed: "1.5.0", available: "1.6.0", isMajor: false)
        #expect(ecosystem.resolveUpdateCommand(for: npmTagged) == nil)
        #expect(!ecosystem.update(npmTagged).didReportSuccess)
        #expect(runner.invocations.isEmpty)
    }
}

@Suite("MacOSUpdateEcosystem")
struct MacOSUpdateEcosystemTests {

    private let path = "/usr/sbin/softwareupdate"

    private func ecosystem(
        available: Bool = true,
        currentVersion: String = "14.5.0",
        handler: @escaping @Sendable (URL, [String]) -> ProcessResult
    ) -> (MacOSUpdateEcosystem, RecordingProcessRunner) {
        var fileSystem = FakeFileSystem()
        if available { fileSystem.addExistingPath(path) }
        let runner = RecordingProcessRunner(handler: handler)
        let ecosystem = MacOSUpdateEcosystem(
            processRunner: runner, fileSystem: fileSystem, softwareUpdatePath: path,
            currentSystemVersion: { currentVersion })
        return (ecosystem, runner)
    }

    private let realCapture = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: Safari27.0TahoeAuto-27.0
        \tTitle: Safari, Version: 27.0, Size: 249465KiB, Recommended: YES, 
        * Label: macOS Tahoe  15.0-25G229
        \tTitle: macOS Tahoe  15.0, Version: 15.0, Size: 2960352KiB, Recommended: YES, Action: restart, 
        """

    @Test("Only the restart-flagged system update gets an installed version to compare against")
    func onlySystemUpdateComparesVersions() {
        let (ecosystem, _) = ecosystem(currentVersion: "14.5.0") { _, _ in
            ProcessResult(exitCode: 1, standardOutput: self.realCapture, standardError: "")
        }
        let packages = ecosystem.check().packages
        #expect(packages.map(\.name) == ["Safari", "macOS Tahoe  15.0"])
        #expect(packages[0].installed == "")
        #expect(packages[1].installed == "14.5.0")
        #expect(packages[1].available == "15.0")
        #expect(packages[1].isMajor)
        #expect(!packages[0].isMajor)
    }

    @Test("No items and a successful exit is up to date")
    func upToDate() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "No new software available.", standardError: "")
        }
        #expect(ecosystem.check() == .upToDate)
    }

    @Test("No items and a failing exit is unknown, not up to date")
    func failureWithNoItems() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "network unreachable")
        }
        #expect(ecosystem.check() == .unknown(.processFailed(exitCode: 1, standardError: "network unreachable")))
    }

    @Test("A real entry survives even when the exit code reports failure")
    func realEntryDespiteFailingExit() {
        let (ecosystem, _) = ecosystem { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "Scan finished with error: denied\n" + self.realCapture,
                standardError: "")
        }
        #expect(ecosystem.check().packages.count == 2)
    }

    @Test("Without softwareupdate the ecosystem is unavailable")
    func unavailable() {
        let (ecosystem, runner) = ecosystem(available: false) { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        #expect(!ecosystem.isAvailable())
        #expect(ecosystem.check() == .unavailable)
        #expect(runner.invocations.isEmpty)
    }

    @Test("Never drivable, and calling update anyway answers honestly")
    func neverDrivable() {
        let (ecosystem, runner) = ecosystem { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let package = OutdatedPackage(
            ecosystem: .macOS, name: "Safari", installed: "", available: "27.0", isMajor: false)
        #expect(ecosystem.resolveUpdateCommand(for: package) == nil)
        #expect(ecosystem.update(package) == .failed(reason: .requiresManualAction))
        #expect(runner.invocations.isEmpty)
    }
}
