import Foundation
import Testing

@testable import OpenFreshrCore

/// Command-shape tests for the three update backends. These pin the *exact*
/// argument vectors the spec mandates and prove the two safety behaviours that
/// matter most: a validated identifier is passed after a separator (never as a
/// flag), and a missing tool degrades to a `nil` command instead of blocking.
struct PackageBackendUpdateTests {

    private func fileSystem(withTools tools: [String]) -> FakeFileSystem {
        var fs = FakeFileSystem()
        for tool in tools { fs.addExistingPath(tool) }
        return fs
    }

    // MARK: - Homebrew

    @Test
    func homebrewUpgradeUsesTheExactGreedyVectorAfterASeparator() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/brew"])
        )

        let command = backend.resolveUpdateCommand(identifier: "figma")
        #expect(command?.executablePath == "/opt/homebrew/bin/brew")
        #expect(command?.arguments == ["upgrade", "--cask", "--greedy", "--", "figma"])

        let result = backend.update(identifier: "figma")
        #expect(result.didReportSuccess)
        #expect(
            runner.invocations == [
                .init(
                    executablePath: "/opt/homebrew/bin/brew",
                    arguments: ["upgrade", "--cask", "--greedy", "--", "figma"])
            ])
    }

    @Test
    func homebrewNeverUsesForce() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/brew"])
        )
        let args = backend.resolveUpdateCommand(identifier: "figma")?.arguments ?? []
        #expect(!args.contains("--force"))
    }

    @Test
    func homebrewAbsentDegradesToNilCommandAndLaunchesNothing() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(processRunner: runner, fileSystem: FakeFileSystem())

        #expect(backend.resolveUpdateCommand(identifier: "figma") == nil)
        let result = backend.update(identifier: "figma")
        if case .failed(.homebrewUnavailable) = result {
        } else {
            Issue.record("expected .homebrewUnavailable, got \(result)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func homebrewRefusesAnInvalidTokenBeforeLaunch() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/brew"])
        )
        #expect(backend.resolveUpdateCommand(identifier: "--force") == nil)
        let result = backend.update(identifier: "--force")
        if case .failed(.invalidCaskToken) = result {
        } else {
            Issue.record("expected .invalidCaskToken, got \(result)")
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - Mac App Store

    @Test
    func masUpgradeUsesTheExactVector() {
        let runner = RecordingProcessRunner()
        let backend = MacAppStoreBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/mas"])
        )

        let command = backend.resolveUpdateCommand(identifier: "497799835")
        #expect(command?.executablePath == "/opt/homebrew/bin/mas")
        #expect(command?.arguments == ["upgrade", "497799835"])

        _ = backend.update(identifier: "497799835")
        #expect(
            runner.invocations == [
                .init(executablePath: "/opt/homebrew/bin/mas", arguments: ["upgrade", "497799835"])
            ])
    }

    @Test
    func masRefusesANonNumericIdBeforeLaunch() {
        let runner = RecordingProcessRunner()
        let backend = MacAppStoreBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/mas"])
        )
        #expect(backend.resolveUpdateCommand(identifier: "com.foo.bar") == nil)
        let result = backend.update(identifier: "com.foo.bar")
        if case .failed(.invalidIdentifier) = result {
        } else {
            Issue.record("expected .invalidIdentifier, got \(result)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func masAbsentDegradesOutdatedProbeToNil() {
        let backend = MacAppStoreBackend(processRunner: RecordingProcessRunner(), fileSystem: FakeFileSystem())
        #expect(backend.isAvailable() == false)
        #expect(backend.outdated() == nil)
        #expect(backend.resolveUpdateCommand(identifier: "497799835") == nil)
    }

    @Test
    func masOutdatedProbeParsesToolOutput() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "497799835 Xcode (14.0 -> 14.1)\n", standardError: "")
        }
        let backend = MacAppStoreBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: ["/opt/homebrew/bin/mas"])
        )
        let entries = backend.outdated()
        #expect(entries?.count == 1)
        #expect(entries?.first?.identifier == "497799835")
        #expect(
            runner.invocations == [
                .init(executablePath: "/opt/homebrew/bin/mas", arguments: ["outdated"])
            ])
    }

    // MARK: - Microsoft AutoUpdate

    @Test
    func msupdateInstallUsesTheExactVectorAtTheSpacedPath() {
        let runner = RecordingProcessRunner()
        let backend = MicrosoftAutoUpdateBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: [MicrosoftAutoUpdateBackend.defaultMsupdatePath])
        )

        let command = backend.resolveUpdateCommand(identifier: "MSWD")
        // The path contains spaces — proof the separated-vector discipline is
        // exactly why no shell string is ever built.
        #expect(command?.executablePath == MicrosoftAutoUpdateBackend.defaultMsupdatePath)
        #expect(command?.executablePath.contains(" ") == true)
        #expect(command?.arguments == ["--install", "--apps", "MSWD"])

        _ = backend.update(identifier: "MSWD")
        #expect(
            runner.invocations == [
                .init(
                    executablePath: MicrosoftAutoUpdateBackend.defaultMsupdatePath,
                    arguments: ["--install", "--apps", "MSWD"])
            ])
    }

    @Test
    func msupdateRefusesAnIdWithSeparatorsBeforeLaunch() {
        let runner = RecordingProcessRunner()
        let backend = MicrosoftAutoUpdateBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: [MicrosoftAutoUpdateBackend.defaultMsupdatePath])
        )
        #expect(backend.resolveUpdateCommand(identifier: "MS WD") == nil)
        #expect(backend.resolveUpdateCommand(identifier: "--apps") == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test
    func msupdateAbsentDegradesListProbeToNil() {
        let backend = MicrosoftAutoUpdateBackend(processRunner: RecordingProcessRunner(), fileSystem: FakeFileSystem())
        #expect(backend.isAvailable() == false)
        #expect(backend.list() == nil)
        #expect(backend.resolveUpdateCommand(identifier: "MSWD") == nil)
    }

    @Test
    func msupdateListProbeParsesToolOutput() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "Word (MSWD2019) 16.78\n", standardError: "")
        }
        let backend = MicrosoftAutoUpdateBackend(
            processRunner: runner,
            fileSystem: fileSystem(withTools: [MicrosoftAutoUpdateBackend.defaultMsupdatePath])
        )
        let entries = backend.list()
        #expect(entries?.count == 1)
        #expect(entries?.first?.appID == "MSWD2019")
        #expect(
            runner.invocations == [
                .init(executablePath: MicrosoftAutoUpdateBackend.defaultMsupdatePath, arguments: ["--list"])
            ])
    }
}
