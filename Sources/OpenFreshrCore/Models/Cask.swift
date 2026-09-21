import Foundation

/// A Homebrew cask definition, reduced to the fields phase 1 needs.
///
/// This mirrors the shape OpenFreshr consumes from the Homebrew cask API, not
/// the full upstream JSON. Two groups of bundle identifiers are kept apart on
/// purpose, because conflating them is exactly what produces the dangerous
/// `Copilot`/`copilot-money` mismatch:
///
/// * ``primaryBundleIdentifiers`` — the cask's **strong** identity, recovered by
///   ``CaskCatalogIngestion`` from the `quit`, `signal`, `launchctl`,
///   `login_item` and `pkgutil` fields of the `uninstall`/`zap` stanzas. These
///   name the cask's own launch agents and packages and are the only positive
///   proof used for corroboration.
/// * ``cleanupBundleIdentifiers`` — identifiers recovered from `trash`/`delete`
///   cleanup *paths* (`~/Library/Containers/<id>`,
///   `~/Library/Preferences/<id>.plist`, …). A cleanup path routinely references
///   *foreign* file debris, so these are **not** treated as proof of identity:
///   they may raise a veto (a contradiction is a contradiction) and may
///   corroborate only as a fallback when the cask declares no strong identity at
///   all. ``MatchResolver`` documents the exact rules.
public struct Cask: Hashable, Sendable, Codable, Identifiable {

    /// Canonical cask token, e.g. `visual-studio-code`. Stable identity.
    public var token: String

    /// Display names the cask advertises (`name` stanza), best-effort.
    public var names: [String]

    /// Prior tokens the cask was published under (`old_tokens`). Relevant because
    /// a renamed cask can still match an app installed under the old name.
    public var oldTokens: [String]

    /// The cask's advertised version, or `nil`/`:latest`. Used together with the
    /// app's versions to predict whether an adopt would hit a version check.
    public var version: String?

    /// `auto_updates true` in the cask.
    ///
    /// Decisive for adopt semantics: when the cask auto-updates, Homebrew
    /// **skips** the version check and the adoption succeeds unconditionally.
    /// That is precisely why a wrong auto-updating cask (copilot-money) is so
    /// dangerous and must be blocked before adoption is ever offered.
    public var autoUpdates: Bool

    /// Homepage URL as a string, best-effort, for display only.
    public var homepage: String?

    /// The cask's one-line description (`desc` stanza), best-effort. Present in
    /// the live Homebrew API and the on-disk cache; the bundled offline snapshot
    /// predates it and simply carries `nil`, so search degrades to token/name
    /// there rather than failing. Used for catalog search and the detail view.
    public var desc: String?

    /// All artifact stanzas the cask declares.
    public var artifacts: [CaskArtifact]

    /// The cask's own **strong** identity bundle IDs (see type doc).
    public var primaryBundleIdentifiers: [String]

    /// Path-derived cleanup bundle IDs the cask references (see type doc).
    public var cleanupBundleIdentifiers: [String]

    public init(
        token: String,
        names: [String] = [],
        oldTokens: [String] = [],
        version: String? = nil,
        autoUpdates: Bool = false,
        homepage: String? = nil,
        desc: String? = nil,
        artifacts: [CaskArtifact] = [],
        primaryBundleIdentifiers: [String] = [],
        cleanupBundleIdentifiers: [String] = []
    ) {
        self.token = token
        self.names = names
        self.oldTokens = oldTokens
        self.version = version
        self.autoUpdates = autoUpdates
        self.homepage = homepage
        self.desc = desc
        self.artifacts = artifacts
        self.primaryBundleIdentifiers = primaryBundleIdentifiers
        self.cleanupBundleIdentifiers = cleanupBundleIdentifiers
    }

    public var id: String { token }

    /// The `app`/`suite` artifacts only — the candidates an app filename can
    /// strongly match.
    public var movedArtifacts: [CaskArtifact] {
        artifacts.filter { $0.kind.isMovedArtifact }
    }

    /// `true` when the cask ships at least one moved (`app`/`suite`) artifact.
    /// Only such casks can be adoption targets at all.
    public var shipsMovedArtifact: Bool {
        artifacts.contains { $0.kind.isMovedArtifact }
    }

    /// `true` when the cask installs via `pkg`/`installer` and ships no moved
    /// artifact — an install-only cask that cannot be adopted losslessly.
    public var isInstallerOnly: Bool {
        !shipsMovedArtifact
            && artifacts.contains {
                $0.kind == .pkg || $0.kind == .installer
            }
    }

    /// All target file names of the cask's moved artifacts, e.g. `["Copilot.app"]`.
    public var movedArtifactTargets: [String] {
        movedArtifacts.compactMap { $0.target }
    }
}
