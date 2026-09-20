import Foundation
import Testing
@testable import OpenFreshrCore

/// The Homebrew backend: explicit `brew` discovery, a separated argument vector
/// with no `--force`, and the distinct classification of a `CaskError` hard-fail.
/// The real `brew` is never launched — a recording fake stands in.
struct HomebrewBackendTests {

    private func fileSystem(brewPaths: [String]) -> FakeFileSystem {
        var fs = FakeFileSystem()
        for path in brewPaths { fs.addExistingPath(path) }
        return fs
    }

    private let appleSiliconBrew = "/opt/homebrew/bin/brew"
    private let intelBrew = "/usr/local/bin/brew"

    private func sampleApp() -> InstalledApp {
        InstalledApp(
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: "com.example.app",
            shortVersion: "1.0.0",
            bundleVersion: "1.0.0"
        )
    }

    // MARK: - brew discovery

    @Test
    func prefersAppleSiliconBrewPath() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew, intelBrew])
        )
        #expect(backend.isAvailable() == true)
        #expect(backend.brewURL()?.path == appleSiliconBrew)
    }

    @Test
    func fallsBackToIntelBrewPath() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [intelBrew])
        )
        #expect(backend.brewURL()?.path == intelBrew)
    }

    @Test
    func reportsUnavailableWhenNoBrewOnDisk() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [])
        )
        #expect(backend.isAvailable() == false)
        #expect(backend.brewURL() == nil)
    }

    @Test
    func adoptFailsCleanlyWhenBrewIsAbsentAndNeverLaunchesAProcess() {
        let runner = RecordingProcessRunner()
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [])
        )

        let result = backend.adopt(app: sampleApp(), caskToken: "example")

        #expect(result == .failed(reason: .homebrewUnavailable))
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - separated arguments, never --force

    @Test
    func adoptUsesSeparatedArgumentsWithoutForce() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "🍺 adopted", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let result = backend.adopt(app: sampleApp(), caskToken: "example")

        #expect(result.didReportSuccess)
        #expect(runner.invocations.count == 1)
        let invocation = runner.invocations[0]
        #expect(invocation.executablePath == appleSiliconBrew)
        // `--` must terminate option parsing right before the token.
        #expect(invocation.arguments == ["install", "--cask", "--adopt", "--", "example"])
        #expect(invocation.arguments.contains("--force") == false)
        // The token is the last argument, guaranteed to sit after the separator.
        #expect(invocation.arguments.last == "example")
        if let separatorIndex = invocation.arguments.firstIndex(of: "--") {
            #expect(separatorIndex == invocation.arguments.count - 2)
        } else {
            Issue.record("expected a `--` separator before the token")
        }
    }

    // MARK: - argument injection: hostile tokens are refused before launch

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

        let result = backend.adopt(app: sampleApp(), caskToken: token)

        guard case let .failed(reason) = result, case .invalidCaskToken = reason else {
            Issue.record("expected .failed(.invalidCaskToken) for \(token), got \(result)")
            return
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test(arguments: ["example", "visual-studio-code", "1password", "font-fira-code", "r", "adobe-acrobat-pro"])
    func acceptsLegitimateCaskTokens(_ token: String) {
        #expect(HomebrewBackend.isValidCaskToken(token))
    }

    // MARK: - CaskError classification

    @Test
    func classifiesExplicitCaskErrorDistinctly() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Error: CaskError: It seems the App source is not there."
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let result = backend.adopt(app: sampleApp(), caskToken: "example")

        guard case let .caskError(message) = result else {
            Issue.record("expected a caskError, got \(result)")
            return
        }
        #expect(message.lowercased().contains("caskerror"))
    }

    @Test
    func classifiesAdoptRefusalAsCaskError() {
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Error: It seems there is already an App at '/Applications/Example.app'; run with --adopt to gain control."
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        guard case .caskError = backend.adopt(app: sampleApp(), caskToken: "example") else {
            Issue.record("adopt version refusal must be classified as a CaskError")
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

        guard case let .failed(reason) = backend.adopt(app: sampleApp(), caskToken: "example"),
              case let .processFailed(exitCode, _) = reason else {
            Issue.record("a non-CaskError non-zero exit must be a processFailed failure")
            return
        }
        #expect(exitCode == 1)
    }

    // MARK: - managed tokens

    @Test
    func parsesManagedTokensFromBrewListOutput() {
        let runner = RecordingProcessRunner { _, arguments in
            #expect(arguments == ["list", "--cask", "-1"])
            return ProcessResult(
                exitCode: 0,
                standardOutput: "1password\nvisual-studio-code\n\ngithub-copilot-app\n",
                standardError: ""
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        #expect(
            backend.managedTokens()
                == ["1password", "visual-studio-code", "github-copilot-app"]
        )
    }

    @Test
    func managedTokensIsEmptyWhenBrewAbsent() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [])
        )
        #expect(backend.managedTokens().isEmpty)
    }

    // MARK: - Receipt versions & the reinstall (drift) command

    @Test
    func parsesReceiptVersionsFromBrewListVersions() {
        // `brew list --cask --versions` prints `token version…` per line. The
        // receipt version is what Homebrew *believes* is installed — captured here
        // so the coordinator can spot the auto_updates drift where it disagrees
        // with the disk.
        let runner = RecordingProcessRunner { _, arguments in
            #expect(arguments == ["list", "--cask", "--versions"])
            return ProcessResult(
                exitCode: 0,
                standardOutput: "transnomino 10.1.0\nwhatsapp 26.34.24\nlibreoffice 26.8.0\n",
                standardError: ""
            )
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        #expect(
            backend.managedReceiptVersions()
                == ["transnomino": "10.1.0", "whatsapp": "26.34.24", "libreoffice": "26.8.0"]
        )
    }

    @Test
    func receiptVersionForATokenWithSeveralVersionsIsTheNewest() {
        // A cask can carry more than one installed version; the receipt we compare
        // against must be the newest, never merely the first printed.
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "thing 1.5.0 2.0.0 1.9.0\n", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        #expect(backend.managedReceiptVersions() == ["thing": "2.0.0"])
    }

    @Test
    func receiptVersionsSkipTokenOnlyLines() {
        // A token with no version column carries no receipt to compare, so it is
        // skipped rather than recorded as an empty (and later mis-ordered) version.
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "lonely\nbaz 1.2.3\n", standardError: "")
        }
        let backend = HomebrewBackend(
            processRunner: runner,
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        #expect(backend.managedReceiptVersions() == ["baz": "1.2.3"])
    }

    @Test
    func managedReceiptVersionsIsEmptyWhenBrewAbsent() {
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [])
        )
        #expect(backend.managedReceiptVersions().isEmpty)
    }

    @Test
    func resolvesReinstallCommandForDriftStrategy() {
        // The drift verb: `brew reinstall --cask -- <token>` — separated arguments,
        // a `--` terminator, and never `--force`, exactly like the upgrade path.
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )

        let reinstall = backend.resolveUpdateCommand(identifier: "transnomino", strategy: .reinstall)
        #expect(reinstall?.arguments == ["reinstall", "--cask", "--", "transnomino"])

        // The default and the explicit upgrade strategy remain the greedy upgrade.
        #expect(
            backend.resolveUpdateCommand(identifier: "transnomino")?.arguments
                == ["upgrade", "--cask", "--greedy", "--", "transnomino"]
        )
        #expect(
            backend.resolveUpdateCommand(identifier: "transnomino", strategy: .upgrade)?.arguments
                == ["upgrade", "--cask", "--greedy", "--", "transnomino"]
        )
    }

    @Test
    func rejectsHostileTokenForReinstallWithoutLaunchingAProcess() {
        // The reinstall path must honour the same allowlist as upgrade/adopt: a
        // token that fails validation yields no command at all.
        let backend = HomebrewBackend(
            processRunner: RecordingProcessRunner(),
            fileSystem: fileSystem(brewPaths: [appleSiliconBrew])
        )
        #expect(backend.resolveUpdateCommand(identifier: "../evil", strategy: .reinstall) == nil)
    }
}
