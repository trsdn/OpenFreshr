import Foundation

/// Globally installed **pipx** packages.
///
/// `pipx` resolves through the same candidate-path pattern as `brew`/`npm`: an
/// absolute path, never `PATH`.
///
/// Verified directly (not assumed) against real `pipx 1.17.3`. This ecosystem
/// was deliberately left unbuilt for a long time (see the project history on
/// issue #29): older `pipx` offered no safe, read-only "what's outdated"
/// command — `pipx upgrade` ran the upgrade immediately, with no dry-run, and
/// the only honest check would have meant a network call to the package index
/// per venv. Current `pipx` has closed that gap: `pipx list --outdated --json`
/// is genuinely read-only (confirmed: running it repeatedly never changes a
/// venv) and returns a clean, structured report — no version-detection or
/// exit-code heuristics needed at all, unlike npm/pnpm's "exits 1 the moment
/// something is outdated" contract.
public struct PipxEcosystem: EcosystemUpdating {

    public let kind: EcosystemKind = .pipx

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidatePipxPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidatePipxPaths: [String] = ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidatePipxPaths = candidatePipxPaths
    }

    private func pipxURL() -> URL? {
        for path in candidatePipxPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool { pipxURL() != nil }

    public func check() -> EcosystemCheck {
        guard let pipx = pipxURL() else { return .unavailable }
        let result: ProcessResult
        do {
            // Queries the package index for every pipx-managed venv, same
            // network shape as npm/pnpm's `outdated`; bounded for the same
            // reason (see ``NpmEcosystem/check()``).
            result = try processRunner.run(
                executableURL: pipx, arguments: ["list", "--outdated", "--json"], environment: nil,
                timeout: 20)
        } catch {
            return .unknown(.launchFailed(message: error.localizedDescription))
        }
        // Verified directly: unlike npm/pnpm, `pipx list --outdated` exits `0`
        // whether or not anything is outdated — the payload alone carries the
        // answer, so there is no exit-code heuristic to get wrong here.
        guard result.exitCode == 0 else {
            return .unknown(.processFailed(exitCode: result.exitCode, standardError: result.standardError))
        }
        guard let packages = Self.parseOutdated(result.standardOutput) else {
            return .unknown(.unparsableOutput)
        }
        return packages.isEmpty ? .upToDate : .outdated(packages)
    }

    public func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? {
        guard package.ecosystem == .pipx, Self.isValidPackageName(package.name), let pipx = pipxURL() else {
            return nil
        }
        return ResolvedCommand(
            executablePath: pipx.path,
            arguments: ["upgrade", "--output", "json", "--", package.name]
        )
    }

    public func update(_ package: OutdatedPackage) -> BackendActionResult {
        guard package.ecosystem == .pipx, Self.isValidPackageName(package.name) else {
            return .failed(reason: .invalidIdentifier(package.name))
        }
        guard let command = resolveUpdateCommand(for: package) else {
            return .failed(reason: .toolUnavailable(tool: "pipx"))
        }
        do {
            let result = try processRunner.run(
                executableURL: URL(fileURLWithPath: command.executablePath), arguments: command.arguments)
            if result.didSucceed { return .succeeded(standardOutput: result.standardOutput) }
            return .failed(
                reason: .processFailed(exitCode: result.exitCode, standardError: result.standardError))
        } catch {
            return .failed(reason: .launchFailed(message: error.localizedDescription))
        }
    }

    // MARK: - Parsing and validation

    private struct Entry: Decodable {
        var package: String
        var version: String
        var latestVersion: String

        enum CodingKeys: String, CodingKey {
            case package
            case version
            case latestVersion = "latest_version"
        }
    }

    private struct Payload: Decodable {
        struct Data: Decodable {
            var packages: [Entry]
        }
        var data: Data
    }

    /// Parses `pipx list --outdated --json`: `{"data": {"packages": [{package,
    /// version, latest_version, …}], …}}`, verified directly against real
    /// `pipx`. Returns `nil` when the output is not the expected shape, so
    /// garbage is never read as "up to date".
    static func parseOutdated(_ output: String) -> [OutdatedPackage]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return decoded.data.packages
            .filter { $0.version != $0.latestVersion }
            .map { entry in
                OutdatedPackage(
                    ecosystem: .pipx,
                    name: entry.package,
                    installed: entry.version,
                    available: entry.latestVersion,
                    isMajor: VersionComparator.isMajorChange(from: entry.version, to: entry.latestVersion)
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// A PyPI-style distribution name: letters, digits, `.`, `_`, `-`, not
    /// starting with `-` or empty — PyPI itself is looser (mixed case,
    /// normalised on the server side) than npm's lowercase-only rule, but the
    /// safety property is the same: nothing here can be parsed as a flag.
    /// Anchored with `\z`, not `$`, so a trailing newline cannot slip through.
    static func isValidPackageName(_ name: String) -> Bool {
        packageNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil
    }

    private static let packageNameRegex = try! NSRegularExpression(
        pattern: "\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z"
    )
}
