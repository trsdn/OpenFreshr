import Foundation

/// Globally installed **npm** packages.
///
/// `npm` resolves through the same candidate-path pattern as `brew`: an absolute
/// path, never `PATH`. The default list covers the common Homebrew installs; a
/// version manager (nvm, volta, fnm, or the toolchain this very repository is
/// built with) puts `npm` somewhere else, and this ecosystem reports
/// ``EcosystemCheck/unavailable`` rather than guess a path. A caller who knows the
/// real path can pass it in `candidateNpmPaths`.
public struct NpmEcosystem: EcosystemUninstalling {

    public let kind: EcosystemKind = .npm

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidateNpmPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidateNpmPaths: [String] = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidateNpmPaths = candidateNpmPaths
    }

    private func npmURL() -> URL? {
        for path in candidateNpmPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool { npmURL() != nil }

    public func check() -> EcosystemCheck {
        guard let npm = npmURL() else { return .unavailable }
        let result: ProcessResult
        do {
            // `npm outdated -g` reaches the registry for every globally installed
            // package; observed directly to hang for minutes with no output on a
            // contended network, so it gets a bound the local-only backends do not
            // need (see ProcessRunning.run(…timeout:)).
            result = try processRunner.run(
                executableURL: npm, arguments: ["outdated", "--global", "--json"], environment: nil,
                timeout: 20)
        } catch {
            return .unknown(.launchFailed(message: error.localizedDescription))
        }
        // `npm outdated` exits 1 the moment anything is outdated — that is its
        // documented success case, not a failure. Only a *non-empty* stderr with
        // that exit code, or any other non-zero code, is a real error.
        guard result.exitCode == 0 || (result.exitCode == 1 && result.standardError.isEmpty) else {
            return .unknown(.processFailed(exitCode: result.exitCode, standardError: result.standardError))
        }
        guard let packages = Self.parseOutdated(result.standardOutput) else {
            return .unknown(.unparsableOutput)
        }
        return packages.isEmpty ? .upToDate : .outdated(packages)
    }

    public func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? {
        guard package.ecosystem == .npm, Self.isValidPackageName(package.name), let npm = npmURL() else {
            return nil
        }
        // `install <name>@latest` rather than `update`: a global install carries no
        // semver range to update *within*, so `npm update` can no-op where this
        // always lands the version the row promised.
        return ResolvedCommand(
            executablePath: npm.path,
            arguments: ["install", "--global", "--", "\(package.name)@latest"]
        )
    }

    public func update(_ package: OutdatedPackage) -> BackendActionResult {
        guard package.ecosystem == .npm, Self.isValidPackageName(package.name) else {
            return .failed(reason: .invalidIdentifier(package.name))
        }
        guard let command = resolveUpdateCommand(for: package) else {
            return .failed(reason: .toolUnavailable(tool: "npm"))
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

    /// The exact `npm uninstall --global -- <name>` command, or `nil` when the
    /// tool is missing or the name fails validation. Verified directly:
    /// `npm uninstall` accepts a `--` separator the same way `install` does.
    public func resolveUninstallCommand(for package: OutdatedPackage) -> ResolvedCommand? {
        guard package.ecosystem == .npm, Self.isValidPackageName(package.name), let npm = npmURL() else {
            return nil
        }
        return ResolvedCommand(
            executablePath: npm.path,
            arguments: ["uninstall", "--global", "--", package.name]
        )
    }

    /// Remove the globally installed npm package `package`. Exists for
    /// ``AppViewModel/retryViaPnpm(_:)``: once pnpm has confirmed it can
    /// manage a package npm itself could not fetch, the stale npm-tracked
    /// copy is removed so `npm outdated` stops reporting it.
    public func uninstall(_ package: OutdatedPackage) -> BackendActionResult {
        guard package.ecosystem == .npm, Self.isValidPackageName(package.name) else {
            return .failed(reason: .invalidIdentifier(package.name))
        }
        guard let command = resolveUninstallCommand(for: package) else {
            return .failed(reason: .toolUnavailable(tool: "npm"))
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

    /// Parses `npm outdated --global --json`: `{ "<name>": { current, wanted,
    /// latest, … } }`, or `{}` when nothing is outdated. `latest` is preferred as
    /// the target version — a global install has no semver range to stay within,
    /// so `wanted` (npm's range-respecting suggestion) is only a fallback when a
    /// registry omits `latest`. An entry missing `current` (not actually
    /// installed, e.g. listed only because it is linked) is skipped. Returns `nil`
    /// when the output is not the expected object, so garbage is never read as
    /// "up to date".
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
                ecosystem: .npm,
                name: name,
                installed: current,
                available: target,
                isMajor: VersionComparator.isMajorChange(from: current, to: target)
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// A bare name (`left-pad`) or a scoped one (`@scope/name`), lowercase with
    /// digits, `.`, `_`, `-` — npm's own naming rules — and not starting with `-`,
    /// which is what keeps a hostile key from `npm outdated`'s JSON from ever being
    /// read as a flag. Anchored with `\z`, not `$`, so a trailing newline cannot
    /// slip through.
    static func isValidPackageName(_ name: String) -> Bool {
        packageNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil
    }

    private static let packageNameRegex = try! NSRegularExpression(
        pattern: "\\A(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*\\z"
    )
}
