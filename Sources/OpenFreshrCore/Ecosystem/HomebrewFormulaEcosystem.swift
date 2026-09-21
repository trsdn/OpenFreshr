import Foundation

/// Homebrew **formulae** (command-line packages), as opposed to the casks
/// ``HomebrewBackend`` handles for apps.
///
/// It finds `brew` the same way the cask backend does and never resolves it
/// through `PATH`. Every formula name comes out of `brew`'s own JSON, which is
/// still external data, so a name is validated before it is put on a command line
/// and follows `--`, so it can never be read as a flag.
public struct HomebrewFormulaEcosystem: EcosystemUpdating {

    public let kind: EcosystemKind = .homebrewFormula

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidateBrewPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidateBrewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidateBrewPaths = candidateBrewPaths
    }

    private func brewURL() -> URL? {
        for path in candidateBrewPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool { brewURL() != nil }

    public func check() -> EcosystemCheck {
        guard let brew = brewURL() else { return .unavailable }
        let result: ProcessResult
        do {
            result = try processRunner.run(
                executableURL: brew,
                arguments: ["outdated", "--formula", "--json=v2"]
            )
        } catch {
            return .unknown(.launchFailed(message: error.localizedDescription))
        }
        guard result.didSucceed else {
            return .unknown(.processFailed(exitCode: result.exitCode, standardError: result.standardError))
        }
        guard let packages = Self.parseOutdated(result.standardOutput) else {
            return .unknown(.unparsableOutput)
        }
        return packages.isEmpty ? .upToDate : .outdated(packages)
    }

    public func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? {
        guard package.ecosystem == .homebrewFormula, Self.isValidFormulaName(package.name),
            let brew = brewURL()
        else { return nil }
        return ResolvedCommand(
            executablePath: brew.path,
            arguments: ["upgrade", "--formula", "--", package.name]
        )
    }

    public func update(_ package: OutdatedPackage) -> BackendActionResult {
        guard package.ecosystem == .homebrewFormula, Self.isValidFormulaName(package.name) else {
            return .failed(reason: .invalidIdentifier(package.name))
        }
        guard let command = resolveUpdateCommand(for: package) else {
            return .failed(reason: .homebrewUnavailable)
        }
        do {
            let result = try processRunner.run(
                executableURL: URL(fileURLWithPath: command.executablePath),
                arguments: command.arguments
            )
            if result.didSucceed { return .succeeded(standardOutput: result.standardOutput) }
            return .failed(
                reason: .processFailed(exitCode: result.exitCode, standardError: result.standardError)
            )
        } catch {
            return .failed(reason: .launchFailed(message: error.localizedDescription))
        }
    }

    // MARK: - Parsing and validation

    private struct Outdated: Decodable {
        struct Formula: Decodable {
            var name: String
            var installedVersions: [String]
            var currentVersion: String
            var pinned: Bool?

            enum CodingKeys: String, CodingKey {
                case name
                case installedVersions = "installed_versions"
                case currentVersion = "current_version"
                case pinned
            }
        }
        var formulae: [Formula]
    }

    /// Parses `brew outdated --formula --json=v2`. A pinned formula is left out on
    /// purpose: the person pinned it to keep it where it is. Returns `nil` when the
    /// output is not the expected JSON, so garbage is never read as "up to date".
    static func parseOutdated(_ output: String) -> [OutdatedPackage]? {
        guard let data = output.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Outdated.self, from: data)
        else { return nil }
        return decoded.formulae.compactMap { formula in
            guard formula.pinned != true, let installed = formula.installedVersions.last else { return nil }
            return OutdatedPackage(
                ecosystem: .homebrewFormula,
                name: formula.name,
                installed: installed,
                available: formula.currentVersion,
                isMajor: VersionComparator.isMajorChange(from: installed, to: formula.currentVersion)
            )
        }
    }

    /// Lowercase letters, digits and `@ + . _ -`, not starting with `-`, with up to
    /// two `/`-separated tap segments (`user/tap/name`). Anything else is refused,
    /// which is what keeps `-v`, `--x=y` or `; rm -rf` away from `brew`. Anchored
    /// with `\z`, not `$`, so a trailing newline cannot slip through.
    static func isValidFormulaName(_ name: String) -> Bool {
        formulaNameRegex.firstMatch(
            in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil
    }

    private static let formulaNameRegex = try! NSRegularExpression(
        pattern: "\\A[a-z0-9][a-z0-9@+._-]*(/[a-z0-9][a-z0-9@+._-]*){0,2}\\z"
    )
}
