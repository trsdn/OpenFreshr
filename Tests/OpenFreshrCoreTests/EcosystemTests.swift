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
