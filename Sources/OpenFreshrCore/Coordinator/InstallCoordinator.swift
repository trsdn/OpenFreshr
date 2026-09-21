import Foundation

/// The result of a fresh install attempt, confirmed by a rescan.
///
/// Mirrors ``AdoptionResult``'s discipline: a backend "success" is never taken
/// at face value. The terminal cases are kept distinct so the UI can react
/// precisely and so success is defined by data — the app actually found on disk
/// (or, for an installer-only cask, a brew receipt) — not by a button handler
/// believing the backend.
///
/// * ``installed`` — the backend reported success **and** a fresh scan found the
///   cask's app bundle on disk. The only "done" for an app cask.
/// * ``installedInstaller`` — an installer-only (`pkg`/`installer`) cask that
///   ships no moved app artifact: there is no bundle to find, so success is
///   confirmed by Homebrew now listing the cask as managed. The install itself
///   ran a privileged installer.
/// * ``alreadyInstalled`` — the cask is already Homebrew-managed; nothing ran.
/// * ``hardFailedWithCaskError`` — Homebrew aborted with a `CaskError`; nothing
///   was installed. Retryable once the cause is understood.
/// * ``failed`` — any other failure (tool missing, invalid token refused before
///   launch, non-zero exit). Retryable.
/// * ``notConfirmedByRescan`` — the backend reported success but the rescan did
///   **not** find the app (nor a receipt): treated as *not done*. Retryable.
public enum InstallResult: Sendable, Equatable {
    case installed(InstalledApp)
    case installedInstaller(token: String)
    case alreadyInstalled(token: String)
    case hardFailedWithCaskError(message: String)
    case failed(reason: BackendFailureReason)
    case notConfirmedByRescan

    /// Whether the cask is now installed as a result of this attempt.
    public var didInstall: Bool {
        switch self {
        case .installed, .installedInstaller:
            return true
        case .alreadyInstalled, .hardFailedWithCaskError, .failed, .notConfirmedByRescan:
            return false
        }
    }

    /// Whether it is sensible to offer the user a retry.
    public var isRetryable: Bool {
        switch self {
        case .installed, .installedInstaller, .alreadyInstalled:
            return false
        case .hardFailedWithCaskError, .failed, .notConfirmedByRescan:
            return true
        }
    }
}

/// Owns the catalog install sequence **install → local scan → confirm**.
///
/// This is the flagship path MacUpdater never had: installing a brand-new app.
/// Like ``AdoptionCoordinator`` it lives in the core, never in a view, so the
/// whole flow is testable without SwiftUI and so success is defined by a
/// confirming rescan rather than by trusting the backend.
///
/// Each ``install(_:)`` call is fully independent: a failure returns a failure
/// result and touches no shared state, so one cask failing never affects another
/// (per-cask error isolation) and any cask can be retried on its own.
public struct InstallCoordinator: Sendable {

    private let scanner: any Scanning
    private let backend: any InstallingBackend
    private let scanDirectories: [String]
    /// Consulted **after** a confirmed app install to record a first-use trust
    /// baseline ("Vertrauensinitialisierung"), so a later update of the freshly
    /// installed app has a baseline to compare against. It never blocks the
    /// install — the app is already on disk by then. `nil` disables it (the
    /// default for install-focused tests).
    private let trustGate: TrustGate?

    public init(
        scanner: any Scanning,
        backend: any InstallingBackend,
        scanDirectories: [String],
        trustGate: TrustGate? = nil
    ) {
        self.scanner = scanner
        self.backend = backend
        self.scanDirectories = scanDirectories
        self.trustGate = trustGate
    }

    /// Install `cask`, then confirm the outcome with a fresh local scan.
    ///
    /// For a cask that ships a moved (`app`/`suite`) artifact, success is
    /// asserted **only** when the post-install scan finds a bundle whose filename
    /// matches one of the cask's artifact targets. For an installer-only cask —
    /// which drops no app to find — success is confirmed by Homebrew now listing
    /// the cask as managed. A backend "success" that neither signal corroborates
    /// is reported as ``InstallResult/notConfirmedByRescan``, never as done.
    public func install(_ cask: Cask) -> InstallResult {
        // Belt-and-suspenders: never re-run an install for a cask Homebrew
        // already manages. The catalog UI marks such casks too, but the
        // coordinator refuses regardless so a stale UI can't trigger a redundant
        // install.
        let preManaged = backend.managedTokens()
        if preManaged.contains(cask.token) {
            return .alreadyInstalled(token: cask.token)
        }

        let action = backend.install(caskToken: cask.token)

        switch action {
        case .caskError(let message):
            return .hardFailedWithCaskError(message: message)

        case .failed(let reason):
            return .failed(reason: reason)

        case .succeeded:
            // Trust nothing the backend claims: perform the local scan the plan
            // calls for and confirm the result against reality.
            let apps = scanner.scan(directories: scanDirectories)

            if cask.shipsMovedArtifact {
                let targets = Set(cask.movedArtifactTargets.map { $0.lowercased() })
                guard
                    let installedApp = apps.first(where: {
                        targets.contains($0.bundleName.lowercased())
                    })
                else {
                    return .notConfirmedByRescan
                }
                // Record a first-use trust baseline for the freshly installed
                // app. Best-effort: the install already happened, so a block here
                // is irrelevant and deliberately ignored.
                if let trustGate {
                    _ = trustGate.authorize(installedApp, acknowledgeTeamChange: false)
                }
                return .installed(installedApp)
            }

            // Installer-only (or otherwise non-moved) cask: there is no app
            // bundle to find, so the confirming signal is Homebrew now managing
            // the cask receipt.
            let postManaged = backend.managedTokens()
            guard postManaged.contains(cask.token) else {
                return .notConfirmedByRescan
            }
            return .installedInstaller(token: cask.token)
        }
    }
}
