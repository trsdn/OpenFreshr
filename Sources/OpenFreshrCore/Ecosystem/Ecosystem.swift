import Foundation

/// A source of updates that is **not an app**: a package manager or the system
/// itself. Apps keep their own model (``SourceUpdate``), which is built around a
/// bundle on disk; a formula, an npm package or a macOS update has no bundle, so
/// it gets this smaller one.
public enum EcosystemKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case homebrewFormula
    case macOS
    case npm
    case pnpm
    case pipx

    public var id: String { rawValue }

    /// Short label for UI and command-line output.
    public var label: String {
        switch self {
        case .homebrewFormula: return String(localized: "Homebrew")
        case .macOS: return String(localized: "macOS")
        case .npm: return String(localized: "npm")
        case .pnpm: return String(localized: "pnpm")
        case .pipx: return String(localized: "pipx")
        }
    }
}

/// One package an ecosystem reports as outdated.
public struct OutdatedPackage: Hashable, Sendable, Identifiable {
    public var ecosystem: EcosystemKind
    /// The name the ecosystem's own command acts on.
    public var name: String
    public var installed: String
    public var available: String
    /// Whether the update changes the first version component, which callers keep
    /// in a separate approval exactly as for apps.
    public var isMajor: Bool
    /// One line saying what the package is, when the ecosystem can supply one —
    /// most package names (`fribidi`, `xxhash`, `httrack`) mean nothing on their
    /// own. `nil` when the ecosystem has no cheap, reliable source for it; a row
    /// with no description is honest, a guessed one would not be.
    public var description: String?

    public var id: String { "\(ecosystem.rawValue):\(name)" }

    public init(
        ecosystem: EcosystemKind,
        name: String,
        installed: String,
        available: String,
        isMajor: Bool,
        description: String? = nil
    ) {
        self.ecosystem = ecosystem
        self.name = name
        self.installed = installed
        self.available = available
        self.isMajor = isMajor
        self.description = description
    }
}

/// Why an ecosystem's state could not be determined.
public enum EcosystemFailure: Hashable, Sendable {
    /// The tool ran but exited non-zero.
    case processFailed(exitCode: Int32, standardError: String)
    /// The process could not be launched at all.
    case launchFailed(message: String)
    /// The tool answered, but not with output this code understands.
    case unparsableOutput

    public var explanation: String {
        switch self {
        case let .processFailed(exitCode, standardError):
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(localized: "Process ended with code \(exitCode): \(trimmed)")
        case let .launchFailed(message):
            return String(localized: "Process could not be started: \(message)")
        case .unparsableOutput:
            return String(localized: "The output could not be understood")
        }
    }
}

/// The result of asking one ecosystem what is outdated.
///
/// The cases are exhaustive and never conflated: ``unknown`` is *not*
/// ``upToDate``. An ecosystem that could not be asked must never read as "nothing
/// to do", which is the same contract the app flow keeps.
public enum EcosystemCheck: Hashable, Sendable {
    case outdated([OutdatedPackage])
    case upToDate
    /// The tool is not installed, so the ecosystem simply does not apply.
    case unavailable
    case unknown(EcosystemFailure)

    public var packages: [OutdatedPackage] {
        if case let .outdated(packages) = self { return packages }
        return []
    }
}

/// A package manager or system updater OpenFreshr can drive.
///
/// Synchronous and process-based, like ``PackageBackend``: every implementation
/// runs its tool through ``ProcessRunning`` with an argument vector and no shell,
/// and validates a name before it reaches a command line.
public protocol EcosystemUpdating: Sendable {
    var kind: EcosystemKind { get }

    /// Whether the tool is installed. `false` degrades the ecosystem to
    /// ``EcosystemCheck/unavailable``; it never crashes the app.
    func isAvailable() -> Bool

    func check() -> EcosystemCheck

    /// The exact command that would update `package`, or `nil` when the tool is
    /// missing or the name fails validation. The same command the preview shows
    /// and ``update(_:)`` runs.
    func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand?

    /// Runs the update. A reported success is only a claim; the coordinator
    /// confirms it by checking again.
    func update(_ package: OutdatedPackage) -> BackendActionResult
}

/// One ecosystem's check, paired with the ecosystem it belongs to.
public struct EcosystemReport: Hashable, Sendable, Identifiable {
    public var kind: EcosystemKind
    public var check: EcosystemCheck
    public var id: String { kind.rawValue }

    public init(kind: EcosystemKind, check: EcosystemCheck) {
        self.kind = kind
        self.check = check
    }
}

/// What happened to one package during an update run.
public struct PackageUpdateResult: Equatable, Sendable, Identifiable {
    public var package: OutdatedPackage
    public var action: BackendActionResult
    /// Whether the package still shows as outdated after a reported success.
    /// `nil` when it could not be confirmed, or the action did not report success.
    public var stillOutdated: Bool?
    public var id: String { package.id }

    /// Confirmed only when the tool reported success **and** the package is gone
    /// from a fresh check.
    public var isVerified: Bool { action.didReportSuccess && stillOutdated == false }

    public init(package: OutdatedPackage, action: BackendActionResult, stillOutdated: Bool?) {
        self.package = package
        self.action = action
        self.stillOutdated = stillOutdated
    }
}

/// Checks and updates every configured ecosystem.
public struct EcosystemCoordinator: Sendable {

    private let ecosystems: [any EcosystemUpdating]

    public init(ecosystems: [any EcosystemUpdating]) {
        self.ecosystems = ecosystems
    }

    /// Checks all ecosystems concurrently. The reports come back in the order the
    /// ecosystems were given, and an unavailable one is reported as such rather
    /// than left out, so a caller can say what was and was not covered.
    public func checkAll() async -> [EcosystemReport] {
        await withTaskGroup(of: (Int, EcosystemReport).self) { group in
            for (index, ecosystem) in ecosystems.enumerated() {
                group.addTask {
                    let check = ecosystem.isAvailable() ? ecosystem.check() : .unavailable
                    return (index, EcosystemReport(kind: ecosystem.kind, check: check))
                }
            }
            var indexed: [(Int, EcosystemReport)] = []
            for await item in group { indexed.append(item) }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Whether OpenFreshr can install `package` itself, i.e. its ecosystem is
    /// configured and offers a command for it. `false` means the person has to
    /// act themselves; a caller should offer to open the right place instead of
    /// calling ``update(_:)``.
    public func canAutomaticallyUpdate(_ package: OutdatedPackage) -> Bool {
        guard let ecosystem = ecosystems.first(where: { $0.kind == package.ecosystem }) else { return false }
        return ecosystem.resolveUpdateCommand(for: package) != nil
    }

    /// Updates the given packages one after another, then checks each affected
    /// ecosystem again so a reported success is confirmed rather than trusted.
    public func update(_ packages: [OutdatedPackage]) async -> [PackageUpdateResult] {
        var results: [PackageUpdateResult] = []
        var recheck: [EcosystemKind: EcosystemCheck] = [:]
        for package in packages {
            guard let ecosystem = ecosystems.first(where: { $0.kind == package.ecosystem }) else {
                results.append(
                    PackageUpdateResult(
                        package: package,
                        action: .failed(reason: .toolUnavailable(tool: package.ecosystem.label)),
                        stillOutdated: nil
                    )
                )
                continue
            }
            let action = ecosystem.update(package)
            var stillOutdated: Bool?
            if action.didReportSuccess {
                if recheck[package.ecosystem] == nil { recheck[package.ecosystem] = ecosystem.check() }
                if case let .outdated(current)? = recheck[package.ecosystem] {
                    stillOutdated = current.contains { $0.name == package.name }
                } else if case .upToDate? = recheck[package.ecosystem] {
                    stillOutdated = false
                }
            }
            results.append(PackageUpdateResult(package: package, action: action, stillOutdated: stillOutdated))
        }
        return results
    }
}
