import Foundation

/// A coding-agent CLI OpenFreshr can hand a difficult update to.
///
/// This exists only for the apps OpenFreshr's own backends cannot drive at all
/// — the ``UpdateBucket/manual`` bucket, where a real update is known but no
/// safe, argv-validated command exists for it. It is a **deliberately weaker**
/// safety story than everything else in this codebase: every other execution
/// path here runs one specific, previewed, argument-vector command with no
/// shell; this runs an autonomous agent that decides its own steps. The prompt
/// (see ``AIUpdateAssistant``) asks it to stay safe, but that is a request to a
/// language model, not a technical guarantee — unlike the trust gate or the
/// strict token validation elsewhere, this cannot be made airtight. It is
/// therefore never offered for a trust-blocked app (the trust gate's authority
/// is not something this is allowed to route around) and always runs as the
/// current user, never elevated.
public enum AIAgentKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case none
    case claudeCode
    case githubCopilot

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return String(localized: "Off")
        case .claudeCode: return String(localized: "Claude Code")
        case .githubCopilot: return String(localized: "GitHub Copilot CLI")
        }
    }

    /// Where this CLI is typically installed. Unlike `brew`/`mas`, these tools
    /// have no one conventional path — they are commonly installed by a native
    /// installer into the user's home directory, by Homebrew, or by npm — so
    /// this is a best-effort list, not a guarantee, and Settings lets a person
    /// override it with the real path when none of these match.
    public func candidatePaths(homeDirectory: String) -> [String] {
        switch self {
        case .none:
            return []
        case .claudeCode:
            return [
                "\(homeDirectory)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        case .githubCopilot:
            // `gh` itself; the `copilot` subcommand is what is actually invoked.
            return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        }
    }

    /// The flag this CLI uses, verified against its own `--help`, that lets it
    /// act without asking for per-step confirmation. Never combined with a
    /// stored credential: both tools are expected to already be signed in
    /// (`claude login` / `gh auth login`), the same as if the person ran them
    /// by hand.
    ///
    /// GitHub Copilot CLI's own equivalent is a per-tool allowlist
    /// (`--allow-tool 'shell(<pattern>)'`, e.g. `shell(brew)`), not a single
    /// "allow everything" flag — no such flag was found in its `--help`, and
    /// none is invented here. Its default scope is deliberately narrow; a
    /// person who wants it broader sets that themselves in Settings.
    public var defaultAutonomyArguments: [String] {
        switch self {
        case .none: return []
        case .claudeCode: return ["--dangerously-skip-permissions"]
        case .githubCopilot: return ["--allow-tool", "shell(brew)"]
        }
    }
}

/// What OpenFreshr tells the agent about the one app it may act on.
public struct AIUpdateRequest: Sendable {
    public var appName: String
    public var bundlePath: String
    public var installedVersion: String?
    public var availableVersion: String?
    /// Why OpenFreshr itself could not drive this update (e.g. "Homebrew
    /// cannot take this app over"), so the agent is not left guessing.
    public var reason: String

    public init(
        appName: String, bundlePath: String, installedVersion: String?, availableVersion: String?,
        reason: String
    ) {
        self.appName = appName
        self.bundlePath = bundlePath
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.reason = reason
    }

    /// The prompt handed to the agent. Explicit about the one thing it may
    /// touch, forbids sudo and forbids touching anything else, and asks it to
    /// stop rather than guess — the request side of the safety story described
    /// on ``AIAgentKind``. A social boundary, not a technical one: nothing here
    /// stops a model that ignores its instructions, which is exactly why this
    /// path is opt-in, per-app, and never offered where the trust gate has
    /// already said no.
    public var prompt: String {
        """
        You are updating exactly one macOS application on this Mac. Do not act on \
        any other application, and do not use sudo or any other privilege \
        escalation — if the update genuinely requires elevated privileges, stop \
        and explain that instead of finding a way around it.

        Application: \(appName)
        Installed at: \(bundlePath)
        Installed version: \(installedVersion ?? "unknown")
        Available version: \(availableVersion ?? "unknown")
        Why OpenFreshr could not update it automatically: \(reason)

        Update this one application to the available version, using only an \
        official source for it (the vendor's own site or update mechanism, or a \
        package manager already on this system). When you are done, state \
        plainly whether it worked. If you cannot do this safely, stop and say why \
        instead of guessing.
        """
    }
}

/// What the agent's process reported. This is a **claim**, exactly like every
/// other backend's `didReportSuccess` — the caller still confirms by rescanning
/// before ever calling it done.
public struct AIUpdateOutcome: Sendable {
    public var didReportSuccess: Bool
    public var output: String

    public init(didReportSuccess: Bool, output: String) {
        self.didReportSuccess = didReportSuccess
        self.output = output
    }
}

public protocol AIUpdateAssisting: Sendable {
    /// The resolved path for `agent`, or `nil` when none of its candidate paths
    /// (or a person's override) exist.
    func resolvedPath(for agent: AIAgentKind) -> String?

    /// Hand `request` to `agent` with `extraArguments` appended after the
    /// autonomy flag, and wait for it to finish. `timeout` bounds an agent
    /// session the same way ``ProcessRunning`` bounds `npm`/`softwareupdate` —
    /// an agentic session can run long, but never unboundedly.
    func run(
        _ request: AIUpdateRequest, agent: AIAgentKind, extraArguments: [String], timeout: TimeInterval
    ) -> AIUpdateOutcome
}

/// Runs the agent CLI as the current user, through the same shell-free
/// ``ProcessRunning`` every other backend uses. Nothing here reads or stores a
/// credential; both CLIs are expected to already be signed in.
public struct SystemAIUpdateAssistant: AIUpdateAssisting {

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let homeDirectory: String
    /// A person's explicit override from Settings, tried before the built-in
    /// candidates — the honest answer to "these tools have no one conventional
    /// install path".
    private let customPaths: [AIAgentKind: String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        homeDirectory: String = NSHomeDirectory(),
        customPaths: [AIAgentKind: String] = [:]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.customPaths = customPaths
    }

    public func resolvedPath(for agent: AIAgentKind) -> String? {
        if let custom = customPaths[agent], fileSystem.fileExists(atPath: custom) {
            return custom
        }
        for path in agent.candidatePaths(homeDirectory: homeDirectory) where fileSystem.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    public func run(
        _ request: AIUpdateRequest, agent: AIAgentKind, extraArguments: [String], timeout: TimeInterval
    ) -> AIUpdateOutcome {
        guard let path = resolvedPath(for: agent) else {
            return AIUpdateOutcome(
                didReportSuccess: false,
                output: String(localized: "\(agent.label) was not found on this Mac."))
        }
        let arguments = Self.arguments(for: agent, prompt: request.prompt) + extraArguments
        do {
            let result = try processRunner.run(
                executableURL: URL(fileURLWithPath: path), arguments: arguments, environment: nil,
                timeout: timeout)
            let combined = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
            return AIUpdateOutcome(didReportSuccess: result.didSucceed, output: combined)
        } catch {
            return AIUpdateOutcome(
                didReportSuccess: false,
                output: String(localized: "\(agent.label) could not be started: \(error.localizedDescription)"))
        }
    }

    /// The base, non-interactive invocation per agent — before
    /// `extraArguments` (the autonomy flag and anything a person added in
    /// Settings, starting from ``AIAgentKind/defaultAutonomyArguments``) is
    /// appended by ``run(_:agent:extraArguments:timeout:)``.
    static func arguments(for agent: AIAgentKind, prompt: String) -> [String] {
        switch agent {
        case .none:
            return []
        case .claudeCode:
            return ["-p", prompt]
        case .githubCopilot:
            return ["copilot", "-p", prompt]
        }
    }
}
