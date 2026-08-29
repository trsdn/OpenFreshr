import Foundation

/// Outcome of a single package-backend action (an adopt attempt).
///
/// The cases separate the three states that must never be conflated:
///
/// * ``succeeded`` — Homebrew reported success. Still only a claim; the
///   coordinator verifies it by rescanning.
/// * ``caskError`` — Homebrew aborted with a `CaskError` (e.g. a version
///   mismatch on a non-auto-updating cask). The app was left untouched. This is
///   a *hard fail with a known cause*, deliberately distinct from a silent no-op.
/// * ``failed`` — any other failure (brew missing, unexpected non-zero exit).
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
    /// `brew` ran but exited non-zero without a recognised `CaskError`.
    case processFailed(exitCode: Int32, standardError: String)
    /// The process could not be launched at all.
    case launchFailed(message: String)
    /// The cask token failed strict validation and was refused **before** any
    /// process was launched. The token comes from external catalog data, so a
    /// value that could be parsed by `brew` as a flag (e.g. `-v`,
    /// `--appdir=/tmp/x`) is rejected rather than passed on.
    case invalidCaskToken(String)

    public var explanation: String {
        switch self {
        case .homebrewUnavailable:
            return "Homebrew wurde nicht gefunden"
        case let .processFailed(exitCode, standardError):
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "brew endete mit Code \(exitCode): \(trimmed)"
        case let .launchFailed(message):
            return "brew konnte nicht gestartet werden: \(message)"
        case let .invalidCaskToken(token):
            return "Ungültiger Cask-Token abgelehnt (nicht ausgeführt): \(token)"
        }
    }
}

/// A package manager OpenFreshr can drive to adopt an app.
///
/// Kept abstract so the Mac App Store / Sparkle / MAU backends of later phases
/// slot in beside Homebrew, and so tests drive a fake instead of the real tool.
public protocol PackageBackend: Sendable {

    /// Whether the backend is usable right now (e.g. Homebrew is installed).
    /// A `false` here must *degrade* the app, never crash it.
    func isAvailable() -> Bool

    /// Cask tokens the backend already manages, for the "already managed" gate.
    /// Returns an empty set when the backend is unavailable.
    func managedTokens() -> Set<String>

    /// Attempt to adopt `app` as `caskToken`.
    func adopt(app: InstalledApp, caskToken: String) -> BackendActionResult
}
