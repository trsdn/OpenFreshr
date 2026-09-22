import Foundation
import Testing

@testable import OpenFreshrCore

/// The Homebrew **uninstall** path (#40): removing a managed cask with the same
/// safety posture as every other action here — explicit `brew`, a separated
/// argument vector, a `--` terminator, never `--force`, never `--zap`, and a
/// strictly validated token refused before any process launches. The real
/// `brew` is never run.
struct HomebrewBackendUninstallTests {

    private func fileSystem(brewPaths: [String]) -> FakeFileSystem {
        var fs = FakeFileSystem()
        for path in brewPaths { fs.addExistingPath(path) }
        return fs
    }

    private let appleSiliconBrew = "/opt/homebrew/bin/brew"

    // MARK: - the exact uninstall command

    @Test
    func uninstallUsesSeparatedArgumentsWithSeparatorNoForceNoZap() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "🍺 uninstalled", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let result = backend.uninstall(caskToken: "example")

        #expect(result.didReportSuccess)
        #expect(runner.invocations.count == 1)
        let invocation = runner.invocations[0]
        #expect(invocation.executablePath == appleSiliconBrew)
        // The flagship command, verbatim: no `--force`, no `--zap`.
        #expect(invocation.arguments == ["uninstall", "--cask", "--", "example"])
        #expect(invocation.arguments.contains("--force") == false)
        #expect(invocation.arguments.contains("--zap") == false)
        #expect(invocation.arguments.last == "example")
        if let separatorIndex = invocation.arguments.firstIndex(of: "--") {
            #expect(separatorIndex == invocation.arguments.count - 2)
        } else {
            Issue.record("expected a `--` separator before the token")
        }
    }

    @Test
    func resolveUninstallCommandMatchesWhatUninstallRuns() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let command = backend.resolveUninstallCommand(identifier: "example")
        #expect(command?.executablePath == appleSiliconBrew)
        #expect(command?.arguments == ["uninstall", "--cask", "--", "example"])
    }

    @Test
    func resolveUninstallCommandIsNilWhenBrewAbsentOrTokenInvalid() {
        let present = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )
        #expect(present.resolveUninstallCommand(identifier: "-v") == nil)

        let absent = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [])
        )
        #expect(absent.resolveUninstallCommand(identifier: "example") == nil)
    }

    // MARK: - brew absent

    @Test
    func uninstallFailsCleanlyWhenBrewIsAbsentAndNeverLaunchesAProcess() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [])
        )

        let result = backend.uninstall(caskToken: "example")

        #expect(result == .failed(reason: .homebrewUnavailable))
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - hostile tokens refused before launch

    @Test(arguments: [
        "-v",
        "--zap",
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

        let result = backend.uninstall(caskToken: token)

        guard case let .failed(reason) = result, case .invalidCaskToken = reason else {
            Issue.record("expected .failed(.invalidCaskToken) for \(token), got \(result)")
            return
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - failure classification

    @Test
    func classifiesSudoRefusalAsRequiresAdministratorPrivileges() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "sudo: a password is required"
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        guard case let .failed(reason) = backend.uninstall(caskToken: "example"),
            case .requiresAdministratorPrivileges = reason
        else {
            Issue.record("a sudo refusal must be classified as requiresAdministratorPrivileges")
            return
        }
    }

    @Test
    func classifiesOtherNonZeroExitAsProcessFailure() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Error: Cask 'example' is not installed."
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        guard case let .failed(reason) = backend.uninstall(caskToken: "example"),
            case .processFailed = reason
        else {
            Issue.record("a plain non-zero exit must be a process failure")
            return
        }
    }
}
