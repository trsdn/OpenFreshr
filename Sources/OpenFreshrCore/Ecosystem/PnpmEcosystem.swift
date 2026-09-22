import Foundation

/// Globally installed **pnpm** packages.
///
/// `pnpm` resolves through the same candidate-path pattern as `brew`/`npm`: an
/// absolute path, never `PATH`. The default list covers the common Homebrew
/// install (`pnpm` there is a corepack shim,
/// `/opt/homebrew/bin/pnpm -> ../lib/node_modules/corepack/dist/pnpm.js`); a
/// version manager puts it somewhere else, and this ecosystem reports
/// ``EcosystemCheck/unavailable`` rather than guess a path.
///
/// Verified directly (not assumed) against real `pnpm 10.33.3`: `pnpm outdated
/// -g --json` shares npm's exact contract — a `{"<name>": {current, wanted,
/// latest, …}}` object (with a couple of pnpm-only fields JSONDecoder simply
/// ignores), an empty `{}` when nothing is outdated, and the same "exits 1 the
/// moment anything is outdated" behaviour npm has. This exists because a
/// corporate npm registry that blocks `npm install`'s fetches outright was
/// observed to let `pnpm add` through unaffected for the exact same package,
/// version and registry — this ecosystem is deliberately generic (no registry
/// or proxy is ever named here), so it works the same way for anyone, not only
/// behind that one feed.
public struct PnpmEcosystem: EcosystemUpdating {

    public let kind: EcosystemKind = .pnpm

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidatePnpmPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidatePnpmPaths: [String] = ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidatePnpmPaths = candidatePnpmPaths
    }

    private func pnpmURL() -> URL? {
        for path in candidatePnpmPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool { pnpmURL() != nil }

    public func check() -> EcosystemCheck {
        guard let pnpm = pnpmURL() else { return .unavailable }
        let result: ProcessResult
        do {
            // Reaches the registry for every globally installed package, same as
            // `npm outdated`; bounded for the same reason (see
            // ``NpmEcosystem/check()``).
            result = try processRunner.run(
                executableURL: pnpm, arguments: ["outdated", "--global", "--json"], environment: nil,
                timeout: 20)
        } catch {
            return .unknown(.launchFailed(message: error.localizedDescription))
        }
        // `pnpm outdated` exits 1 the moment anything is outdated — verified
        // directly, and identical to npm's own contract. Only a *non-empty*
        // stderr with that exit code, or any other non-zero code, is a real
        // error.
        guard result.exitCode == 0 || (result.exitCode == 1 && result.standardError.isEmpty) else {
            return .unknown(.processFailed(exitCode: result.exitCode, standardError: result.standardError))
        }
        guard let packages = Self.parseOutdated(result.standardOutput) else {
            return .unknown(.unparsableOutput)
        }
        return packages.isEmpty ? .upToDate : .outdated(packages)
    }

    public func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? {
        guard package.ecosystem == .pnpm, Self.isValidPackageName(package.name), let pnpm = pnpmURL() else {
            return nil
        }
        // `add <name>@latest` rather than `update`: a global install carries no
        // semver range to update *within*, so `pnpm update` can no-op where this
        // always lands the version the row promised — same reasoning as npm's
        // `install <name>@latest`.
        return ResolvedCommand(
            executablePath: pnpm.path,
            arguments: ["add", "--global", "--", "\(package.name)@latest"]
        )
    }

    public func update(_ package: OutdatedPackage) -> BackendActionResult {
        guard package.ecosystem == .pnpm, Self.isValidPackageName(package.name) else {
            return .failed(reason: .invalidIdentifier(package.name))
        }
        guard let command = resolveUpdateCommand(for: package) else {
            return .failed(reason: .toolUnavailable(tool: "pnpm"))
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
        var current: String?
        var wanted: String?
        var latest: String?
    }

    /// Parses `pnpm outdated --global --json`: `{ "<name>": { current, wanted,
    /// latest, … } }`, or `{}` when nothing is outdated — the exact shape
    /// ``NpmEcosystem/parseOutdated(_:)`` parses, verified directly against real
    /// `pnpm`. `latest` is preferred as the target version for the same reason:
    /// a global install has no semver range to stay within. An entry missing
    /// `current` is skipped. Returns `nil` when the output is not the expected
    /// object, so garbage is never read as "up to date".
    static func parseOutdated(_ output: String) -> [OutdatedPackage]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return nil }
        return decoded.compactMap { name, entry in
            guard let current = entry.current, let target = entry.latest ?? entry.wanted, target != current
            else { return nil }
            return OutdatedPackage(
                ecosystem: .pnpm,
                name: name,
                installed: current,
                available: target,
                isMajor: VersionComparator.isMajorChange(from: current, to: target)
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Same naming rules as npm's — pnpm packages live in the same npm registry
    /// namespace. A bare name (`left-pad`) or a scoped one (`@scope/name`),
    /// lowercase with digits, `.`, `_`, `-`, not starting with `-`. Anchored with
    /// `\z`, not `$`, so a trailing newline cannot slip through.
    static func isValidPackageName(_ name: String) -> Bool {
        packageNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil
    }

    private static let packageNameRegex = try! NSRegularExpression(
        pattern: "\\A(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*\\z"
    )
}
