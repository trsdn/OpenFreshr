import Foundation

/// macOS's own updates (system, Safari, Command Line Tools, …), from
/// `softwareupdate --list`.
///
/// This ecosystem only ever **detects**; it never installs. `softwareupdate
/// --install` can need elevated privileges and can require a restart, and
/// OpenFreshr has no privileged helper (a deliberate non-goal — see the PRD) and
/// stores no password. ``resolveUpdateCommand(for:)`` therefore always returns
/// `nil`, and ``update(_:)`` always answers ``BackendFailureReason/requiresManualAction``;
/// a caller should offer to open System Settings instead of calling it.
public struct MacOSUpdateEcosystem: EcosystemUpdating {

    public let kind: EcosystemKind = .macOS

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let softwareUpdatePath: String
    /// Injectable so a test can fix the comparison version; defaults to the real
    /// running system.
    private let currentSystemVersion: @Sendable () -> String

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        softwareUpdatePath: String = "/usr/sbin/softwareupdate",
        currentSystemVersion: @escaping @Sendable () -> String = MacOSUpdateEcosystem.liveSystemVersion
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.softwareUpdatePath = softwareUpdatePath
        self.currentSystemVersion = currentSystemVersion
    }

    public func isAvailable() -> Bool { fileSystem.fileExists(atPath: softwareUpdatePath) }

    public func check() -> EcosystemCheck {
        guard isAvailable() else { return .unavailable }
        let result: ProcessResult
        do {
            // Apple's own tool does a real network scan and was observed directly
            // to report another caller is already using it and then never return;
            // bounded for the same reason as NpmEcosystem.
            result = try processRunner.run(
                executableURL: URL(fileURLWithPath: softwareUpdatePath), arguments: ["--list"],
                environment: nil, timeout: 45)
        } catch {
            return .unknown(.launchFailed(message: error.localizedDescription))
        }
        // Apple's own tool prints an error banner *ahead of* a still-valid,
        // possibly-cached listing (observed directly: "Scan finished with error:
        // … Access request was denied" followed by real entries) and a non-zero
        // exit even then, so the exit code alone cannot decide success. The
        // listing itself — did it contain a real entry — is the authoritative
        // signal; an exit failure with nothing parsed is a real unknown.
        let items = SoftwareUpdateListParser.parse(result.standardOutput)
        if items.isEmpty {
            guard result.didSucceed else {
                return .unknown(.processFailed(exitCode: result.exitCode, standardError: result.standardError))
            }
            return .upToDate
        }
        return .outdated(items.map { package(for: $0) })
    }

    /// Never drivable: see the type documentation.
    public func resolveUpdateCommand(for package: OutdatedPackage) -> ResolvedCommand? { nil }

    /// Never called for a package this ecosystem produced without the caller
    /// choosing to bypass ``resolveUpdateCommand(for:)``'s `nil`; answers honestly
    /// rather than pretending to try.
    public func update(_ package: OutdatedPackage) -> BackendActionResult {
        .failed(reason: .requiresManualAction)
    }

    // MARK: - Mapping

    private func package(for item: SoftwareUpdateItem) -> OutdatedPackage {
        // Only an actual macOS system update (the one entry with `Action:
        // restart`) is meaningfully "installed X, available Y" against the
        // running system; Safari or Command Line Tools have no such single
        // "installed version" this tool reports, so the comparison is left blank
        // rather than guessed.
        let installed = item.requiresRestart ? currentSystemVersion() : ""
        let available = item.version ?? item.title
        return OutdatedPackage(
            ecosystem: .macOS,
            name: item.title,
            installed: installed,
            available: available,
            isMajor: item.requiresRestart && !installed.isEmpty
                ? VersionComparator.isMajorChange(from: installed, to: available) : false
        )
    }

    public static func liveSystemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
