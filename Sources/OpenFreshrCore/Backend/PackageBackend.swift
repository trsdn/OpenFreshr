import Foundation

/// Outcome of a single package-backend action (an adopt or update attempt).
///
/// The cases separate the three states that must never be conflated:
///
/// * ``succeeded`` — the tool reported success. Still only a claim; the
///   coordinator verifies it by rescanning.
/// * ``caskError`` — the tool aborted with a known, reported error (e.g. a
///   version mismatch on a non-auto-updating cask). The app was left untouched.
///   This is a *hard fail with a known cause*, deliberately distinct from a
///   silent no-op.
/// * ``failed`` — any other failure (tool missing, unexpected non-zero exit).
public enum BackendActionResult: Sendable, Equatable {
    case succeeded(standardOutput: String)
    case caskError(message: String)
    case failed(reason: BackendFailureReason)

    public var didReportSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

/// Why a backend action failed for reasons other than a `CaskError`.
public enum BackendFailureReason: Sendable, Equatable {
    /// No usable `brew` executable was found on disk.
    case homebrewUnavailable
    /// A required tool (`mas`, `msupdate`) was not found on disk. Carries the
    /// tool name for the message.
    case toolUnavailable(tool: String)
    /// The tool ran but exited non-zero without a recognised error.
    case processFailed(exitCode: Int32, standardError: String)
    /// The process could not be launched at all.
    case launchFailed(message: String)
    /// The cask token failed strict validation and was refused **before** any
    /// process was launched. The token comes from external catalog data, so a
    /// value that could be parsed by `brew` as a flag (e.g. `-v`,
    /// `--appdir=/tmp/x`) is rejected rather than passed on.
    case invalidCaskToken(String)
    /// A store/MAU identifier failed strict validation and was refused before
    /// any process was launched.
    case invalidIdentifier(String)

    public var explanation: String {
        switch self {
        case .homebrewUnavailable:
            return "Homebrew wurde nicht gefunden"
        case let .toolUnavailable(tool):
            return "\(tool) wurde nicht gefunden"
        case let .processFailed(exitCode, standardError):
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Prozess endete mit Code \(exitCode): \(trimmed)"
        case let .launchFailed(message):
            return "Prozess konnte nicht gestartet werden: \(message)"
        case let .invalidCaskToken(token):
            return "Ungültiger Cask-Token abgelehnt (nicht ausgeführt): \(token)"
        case let .invalidIdentifier(identifier):
            return "Ungültiger Bezeichner abgelehnt (nicht ausgeführt): \(identifier)"
        }
    }
}

/// A package manager OpenFreshr can drive to **update** an already-installed app.
///
/// This is the common denominator across Homebrew, the Mac App Store and
/// Microsoft AutoUpdate: each can resolve and run an update command for an
/// identifier it owns. Adoption is layered on top in ``AdoptingBackend`` because
/// only Homebrew adopts.
public protocol PackageBackend: Sendable {

    /// Whether the backend is usable right now (e.g. the tool is installed).
    /// A `false` here must *degrade* the affected source, never crash the app.
    func isAvailable() -> Bool

    /// The exact command that would update `identifier`, or `nil` when the tool
    /// is unavailable or the identifier fails validation. Same command the
    /// preview shows and ``update(identifier:)`` runs — a single source of truth.
    func resolveUpdateCommand(identifier: String) -> ResolvedCommand?

    /// Run the update for `identifier`. The reported success is only a claim;
    /// the coordinator confirms it by rescanning.
    func update(identifier: String) -> BackendActionResult
}

/// A ``PackageBackend`` that can additionally **adopt** an unmanaged app —
/// i.e. bring it under management for the first time. Only Homebrew does this.
public protocol AdoptingBackend: PackageBackend {

    /// Cask tokens the backend already manages, for the "already managed" gate.
    /// Returns an empty set when the backend is unavailable.
    func managedTokens() -> Set<String>

    /// Attempt to adopt `app` as `caskToken`.
    func adopt(app: InstalledApp, caskToken: String) -> BackendActionResult
}
