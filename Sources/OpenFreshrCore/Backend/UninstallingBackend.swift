import Foundation

/// A ``PackageBackend`` that can additionally **remove** an app it manages.
/// Only Homebrew does this today; there is deliberately no way here to remove
/// an app OpenFreshr did not itself confirm as managed — see
/// ``AppReport/managedCaskToken``, the single gate the UI checks before this is
/// ever offered.
public protocol UninstallingBackend: PackageBackend {

    /// Cask tokens the backend already manages. Used to refuse an uninstall for
    /// a token that is not (or no longer) managed — never running a command for
    /// something OpenFreshr does not actually control — and to confirm, by its
    /// *absence* afterwards, that the removal actually happened.
    func managedTokens() -> Set<String>

    /// The exact `brew uninstall --cask -- <token>` command, or `nil` when the
    /// tool is unavailable or the token fails validation. The same command the
    /// confirmation dialog shows and ``uninstall(caskToken:)`` runs — a single
    /// source of truth.
    func resolveUninstallCommand(identifier: String) -> ResolvedCommand?

    /// Remove the cask `caskToken`. The reported success is only a claim; the
    /// coordinator confirms it by rechecking the managed set.
    func uninstall(caskToken: String) -> BackendActionResult
}
