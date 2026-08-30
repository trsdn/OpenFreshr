import Foundation

/// A ``PackageBackend`` that can additionally **install a brand-new cask** —
/// an app the machine does not have yet. This is the catalog's flagship path and
/// is kept separate from ``AdoptingBackend`` so the shared update/adopt
/// protocols gain no new requirements: only Homebrew installs new casks, and it
/// conforms to this in addition to ``AdoptingBackend``.
///
/// The same standing safety rules apply as for adoption and update: a separated
/// argument vector, a `--` terminator, a strictly validated token refused before
/// any process launches, an absolute executable path, and **never** `--force`.
public protocol InstallingBackend: PackageBackend {

    /// Cask tokens the backend already manages. Used to confirm an
    /// installer-only cask actually installed (it drops no app bundle to find on
    /// disk) and to skip casks that are already managed. Empty when unavailable.
    func managedTokens() -> Set<String>

    /// The exact `brew install --cask -- <token>` command, or `nil` when the
    /// tool is unavailable or the token fails validation. The same command the
    /// preview shows and ``install(caskToken:)`` runs — a single source of truth.
    func resolveInstallCommand(identifier: String) -> ResolvedCommand?

    /// Install the new cask `caskToken`. The reported success is only a claim;
    /// the coordinator confirms it by rescanning the disk.
    func install(caskToken: String) -> BackendActionResult
}
