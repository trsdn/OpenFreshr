import Foundation

/// The result of an uninstall attempt, confirmed by rechecking the managed set.
///
/// Mirrors ``InstallResult``'s discipline in reverse: a backend "success" is
/// never taken at face value. Success is defined by data — the cask token no
/// longer present in ``UninstallingBackend/managedTokens()`` — not by a button
/// handler believing the backend.
///
/// * ``uninstalled`` — the backend reported success **and** a fresh check shows
///   the token is no longer managed. The only "done" here.
/// * ``notManaged`` — the token was not (or no longer) managed before the
///   attempt even started; refused before any process ran, so a stale UI can
///   never trigger a redundant or wrong-app removal.
/// * ``hardFailedWithCaskError`` — Homebrew aborted with a `CaskError`; nothing
///   was removed.
/// * ``failed`` — any other failure (tool missing, invalid token refused before
///   launch, non-zero exit, or the sudo refusal a `zap`-free uninstall can still
///   hit for some casks).
/// * ``notConfirmedByRescan`` — the backend reported success but the token is
///   still in the managed set afterwards: treated as *not done*.
public enum UninstallResult: Sendable, Equatable {
    case uninstalled(caskToken: String)
    case notManaged(caskToken: String)
    case hardFailedWithCaskError(message: String)
    case failed(reason: BackendFailureReason)
    case notConfirmedByRescan

    /// Whether the cask is confirmed gone as a result of this attempt.
    public var didUninstall: Bool {
        if case .uninstalled = self { return true }
        return false
    }

    /// Whether it is sensible to offer the user a retry.
    public var isRetryable: Bool {
        switch self {
        case .uninstalled, .notManaged:
            return false
        case .hardFailedWithCaskError, .failed, .notConfirmedByRescan:
            return true
        }
    }
}

/// Owns the removal sequence **verify managed → uninstall → confirm**, for a
/// Homebrew-managed app only.
///
/// Scoped deliberately narrowly: an app OpenFreshr did not itself confirm as
/// Homebrew-managed (see ``AppReport/managedCaskToken``) has no safe,
/// argv-validated removal command here at all — removing a non-managed app
/// would mean OpenFreshr deleting the `.app` bundle itself, a different and
/// riskier action that this coordinator does not attempt.
///
/// Lives in the core, never in a view, so the flow is testable without SwiftUI
/// and so success is defined by a confirming recheck rather than by trusting
/// the backend. Each ``uninstall(caskToken:)`` call is fully independent.
public struct UninstallCoordinator: Sendable {

    private let backend: any UninstallingBackend

    public init(backend: any UninstallingBackend) {
        self.backend = backend
    }

    /// Remove `caskToken`, then confirm the outcome by rechecking the managed
    /// set.
    public func uninstall(caskToken: String) -> UninstallResult {
        // Belt-and-suspenders: never run an uninstall for a token that is not
        // currently managed. The UI gates the button on the same fact, but the
        // coordinator refuses regardless so a stale UI can't trigger a wrong
        // removal.
        let preManaged = backend.managedTokens()
        guard preManaged.contains(caskToken) else {
            return .notManaged(caskToken: caskToken)
        }

        let action = backend.uninstall(caskToken: caskToken)

        switch action {
        case .caskError(let message):
            return .hardFailedWithCaskError(message: message)

        case .failed(let reason):
            return .failed(reason: reason)

        case .succeeded:
            // Trust nothing the backend claims: recheck the managed set and
            // confirm the token is actually gone from it.
            let postManaged = backend.managedTokens()
            guard !postManaged.contains(caskToken) else {
                return .notConfirmedByRescan
            }
            return .uninstalled(caskToken: caskToken)
        }
    }
}
