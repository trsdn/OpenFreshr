import Foundation

/// One catalog entry as the UI consumes it: the ``Cask`` plus the few derived
/// facts a row and the detail pane need, so the main actor never recomputes
/// popularity, installed-state or the artifact kind while scrolling or typing.
///
/// It is a value type carrying only `Sendable` data, so a fully ranked result
/// list can be built off the main actor and handed across the actor boundary.
public struct CatalogSearchResult: Sendable, Identifiable, Equatable {

    /// The catalog definition this result stands for.
    public var cask: Cask

    /// 365-day install count from the analytics source, when that source knows
    /// the token. `nil` means "no popularity data" — which must never be read as
    /// zero interest, only as unknown.
    public var installCount: Int?

    /// The cask maps to an app that is already installed or otherwise recognized
    /// on this machine, so the catalog can warn the user before a redundant
    /// install.
    public var isInstalled: Bool

    /// The filename of the installed bundle this cask maps to, when installed and
    /// known (e.g. `"Firefox.app"`) — for the detail pane's "already installed"
    /// line. `nil` when the cask is recognized only by token.
    public var installedBundleName: String?

    /// The cask installs via `pkg`/`installer` and ships no moved app artifact,
    /// so installing it launches a privileged installer rather than dropping an
    /// app in place. The UI flags this before offering to install.
    public var isInstallerOnly: Bool

    public init(
        cask: Cask,
        installCount: Int? = nil,
        isInstalled: Bool = false,
        installedBundleName: String? = nil,
        isInstallerOnly: Bool = false
    ) {
        self.cask = cask
        self.installCount = installCount
        self.isInstalled = isInstalled
        self.installedBundleName = installedBundleName
        self.isInstallerOnly = isInstallerOnly
    }

    public var id: String { cask.token }

    /// The human name to show: the cask's first declared name, falling back to
    /// the token when a cask carries no name.
    public var displayName: String {
        cask.names.first ?? cask.token
    }
}
