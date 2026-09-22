import Foundation
import Testing

@testable import OpenFreshrCore

@Suite("AIAgentKind")
struct AIAgentKindTests {

    @Test("Claude Code resolves under the person's home directory")
    func claudeCandidatePaths() {
        let paths = AIAgentKind.claudeCode.candidatePaths(homeDirectory: "/Users/demo")
        #expect(paths.contains("/Users/demo/.local/bin/claude"))
    }

    @Test("GitHub Copilot's candidates are gh itself, not a copilot binary")
    func copilotCandidatePaths() {
        let paths = AIAgentKind.githubCopilot.candidatePaths(homeDirectory: "/Users/demo")
        #expect(paths.allSatisfy { $0.hasSuffix("/gh") })
    }

    @Test("Off has no candidate paths and is never resolvable")
    func offHasNoCandidates() {
        #expect(AIAgentKind.none.candidatePaths(homeDirectory: "/Users/demo").isEmpty)
    }
}

@Suite("SystemAIUpdateAssistant")
struct SystemAIUpdateAssistantTests {

    private func request(reason: String = "Homebrew cannot take this app over.") -> AIUpdateRequest {
        AIUpdateRequest(
            appName: "Demo", bundlePath: "/Applications/Demo.app", installedVersion: "1.0",
            availableVersion: "2.0", reason: reason)
    }

    @Test("Resolves the first existing candidate path, in order")
    func resolvesFirstExistingCandidate() {
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/claude")
        let assistant = SystemAIUpdateAssistant(
            processRunner: RecordingProcessRunner(), fileSystem: fileSystem, homeDirectory: "/Users/demo")
        #expect(assistant.resolvedPath(for: .claudeCode) == "/opt/homebrew/bin/claude")
    }

    @Test("A custom path from Settings is tried before the built-in candidates")
    func customPathWins() {
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/claude")
        fileSystem.addExistingPath("/custom/claude")
        let assistant = SystemAIUpdateAssistant(
            processRunner: RecordingProcessRunner(), fileSystem: fileSystem, homeDirectory: "/Users/demo",
            customPaths: [.claudeCode: "/custom/claude"])
        #expect(assistant.resolvedPath(for: .claudeCode) == "/custom/claude")
    }

    @Test("A custom path that does not exist on disk is not used")
    func customPathMustExist() {
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/claude")
        let assistant = SystemAIUpdateAssistant(
            processRunner: RecordingProcessRunner(), fileSystem: fileSystem, homeDirectory: "/Users/demo",
            customPaths: [.claudeCode: "/custom/claude"])
        #expect(assistant.resolvedPath(for: .claudeCode) == "/opt/homebrew/bin/claude")
    }

    @Test("Nothing found means nil, not a guess")
    func nothingFound() {
        let assistant = SystemAIUpdateAssistant(
            processRunner: RecordingProcessRunner(), fileSystem: FakeFileSystem(), homeDirectory: "/Users/demo")
        #expect(assistant.resolvedPath(for: .claudeCode) == nil)
    }

    @Test("Claude Code is invoked with -p, the prompt, then the extra arguments verbatim")
    func claudeInvocationShape() {
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/claude")
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "done", standardError: "")
        }
        let assistant = SystemAIUpdateAssistant(
            processRunner: runner, fileSystem: fileSystem, homeDirectory: "/Users/demo")

        let outcome = assistant.run(
            request(), agent: .claudeCode, extraArguments: ["--dangerously-skip-permissions"], timeout: 5)

        #expect(outcome.didReportSuccess)
        #expect(runner.invocations.count == 1)
        let call = runner.invocations[0]
        #expect(call.executablePath == "/opt/homebrew/bin/claude")
        #expect(call.arguments.first == "-p")
        #expect(call.arguments[1].contains("Demo"))
        #expect(call.arguments.last == "--dangerously-skip-permissions")
    }

    @Test("GitHub Copilot is invoked as the copilot subcommand of gh")
    func copilotInvocationShape() {
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/gh")
        let runner = RecordingProcessRunner { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "done", standardError: "")
        }
        let assistant = SystemAIUpdateAssistant(
            processRunner: runner, fileSystem: fileSystem, homeDirectory: "/Users/demo")

        _ = assistant.run(
            request(), agent: .githubCopilot, extraArguments: ["--allow-tool", "shell(brew)"], timeout: 5)

        let call = runner.invocations[0]
        #expect(call.executablePath == "/opt/homebrew/bin/gh")
        #expect(Array(call.arguments.prefix(2)) == ["copilot", "-p"])
        #expect(call.arguments.suffix(2) == ["--allow-tool", "shell(brew)"])
    }

    @Test("An unresolvable agent fails without launching any process")
    func unresolvedAgentNeverLaunches() {
        let runner = RecordingProcessRunner()
        let assistant = SystemAIUpdateAssistant(
            processRunner: runner, fileSystem: FakeFileSystem(), homeDirectory: "/Users/demo")

        let outcome = assistant.run(request(), agent: .claudeCode, extraArguments: [], timeout: 5)

        #expect(!outcome.didReportSuccess)
        #expect(runner.invocations.isEmpty)
    }

    @Test("The prompt names the one app, forbids sudo, and carries the reason OpenFreshr gives")
    func promptContent() {
        let text = request(reason: "No automatic way to update it").prompt
        #expect(text.contains("Demo"))
        #expect(text.contains("/Applications/Demo.app"))
        #expect(text.contains("sudo"))
        #expect(text.contains("No automatic way to update it"))
        #expect(text.contains("1.0"))
        #expect(text.contains("2.0"))
    }

    @Test("A launch failure is reported, not silently swallowed, and never claims success")
    func launchFailureIsReported() {
        struct ThrowingRunner: ProcessRunning {
            func run(executableURL: URL, arguments: [String], environment: [String: String]?) throws -> ProcessResult {
                struct Boom: Error {}
                throw Boom()
            }
        }
        var fileSystem = FakeFileSystem()
        fileSystem.addExistingPath("/opt/homebrew/bin/claude")
        let assistant = SystemAIUpdateAssistant(
            processRunner: ThrowingRunner(), fileSystem: fileSystem, homeDirectory: "/Users/demo")

        let outcome = assistant.run(request(), agent: .claudeCode, extraArguments: [], timeout: 5)
        #expect(!outcome.didReportSuccess)
        #expect(!outcome.output.isEmpty)
    }
}
