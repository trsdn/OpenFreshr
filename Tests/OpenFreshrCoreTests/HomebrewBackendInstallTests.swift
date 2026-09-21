import Foundation
import Testing

@testable import OpenFreshrCore

/// The Homebrew **install** path (Phase 5): a fresh `brew install --cask -- <token>`
/// with the same safety posture as adoption — explicit `brew`, a separated
/// argument vector, a `--` terminator, never `--force`, and a strictly validated
/// token refused before any process launches. The real `brew` is never run.
struct HomebrewBackendInstallTests {

    private func fileSystem(brewPaths: [String]) -> FakeFileSystem {
        var fs = FakeFileSystem()
        for path in brewPaths { fs.addExistingPath(path) }
        return fs
    }

    private let appleSiliconBrew = "/opt/homebrew/bin/brew"

    // MARK: - the exact install command

    @Test
    func installUsesSeparatedArgumentsWithSeparatorAndNoForce() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "🍺 installed", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let result = backend.install(caskToken: "example")

        #expect(result.didReportSuccess)
        #expect(runner.invocations.count == 1)
        let invocation = runner.invocations[0]
        #expect(invocation.executablePath == appleSiliconBrew)
        // The flagship command, verbatim: no `--adopt`, no `--greedy`, no `--force`.
        #expect(invocation.arguments == ["install", "--cask", "--", "example"])
        #expect(invocation.arguments.contains("--force") == false)
        #expect(invocation.arguments.contains("--adopt") == false)
        #expect(invocation.arguments.last == "example")
        if let separatorIndex = invocation.arguments.firstIndex(of: "--") {
            #expect(separatorIndex == invocation.arguments.count - 2)
        } else {
            Issue.record("expected a `--` separator before the token")
        }
    }

    @Test
    func resolveInstallCommandMatchesWhatInstallRuns() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let command = backend.resolveInstallCommand(identifier: "example")
        #expect(command?.executablePath == appleSiliconBrew)
        #expect(command?.arguments == ["install", "--cask", "--", "example"])
    }

    @Test
    func resolveInstallCommandIsNilWhenBrewAbsentOrTokenInvalid() {
        let present = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )
        #expect(present.resolveInstallCommand(identifier: "-v") == nil)

        let absent = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [])
        )
        #expect(absent.resolveInstallCommand(identifier: "example") == nil)
    }

    // MARK: - brew absent

    @Test
    func installFailsCleanlyWhenBrewIsAbsentAndNeverLaunchesAProcess() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [])
        )

        let result = backend.install(caskToken: "example")

        #expect(result == .failed(reason: .homebrewUnavailable))
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - hostile tokens refused before launch

    @Test(arguments: [
        "-v",
        "--appdir=/tmp/x",
        "--force",
        "; rm -rf /",
        "example token",
        "-",
        "",
        "Example",
        "../evil",
        "token\n--force",
    ])
    func rejectsHostileCaskTokenWithoutLaunchingAProcess(_ token: String) {
        let runner = RecordingProcessRunner { _, _ in
            Issue.record("brew must never be launched for an invalid token: \(token)")
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let result = backend.install(caskToken: token)

        guard case let .failed(reason) = result, case .invalidCaskToken = reason else {
            Issue.record("expected .failed(.invalidCaskToken) for \(token), got \(result)")
            return
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - failure classification

    @Test
    func classifiesExistingAppRefusalAsCaskError() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError:
                    "Error: It seems there is already an App at '/Applications/Example.app'; run with --adopt to gain control."
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        guard case .caskError = backend.install(caskToken: "example") else {
            Issue.record("an existing-app refusal must be classified as a CaskError")
            return
        }
    }

    @Test
    func classifiesOtherNonZeroExitAsProcessFailure() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Error: Download failed on Cask 'example'."
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        guard case let .failed(reason) = backend.install(caskToken: "example"),
            case .processFailed = reason
        else {
            Issue.record("a plain non-zero exit must be a process failure, not a CaskError")
            return
        }
    }
}
