import Foundation

/// The executable update mechanism that can drive a source, when one exists.
///
/// Sparkle deliberately has no case: a Sparkle app updates itself, and OpenFreshr
/// must never launch a second updater against a bundle a first one already owns.
public enum UpdateBackendKind: String, Hashable, Sendable {
    case homebrew
    case macAppStore
    case microsoftAutoUpdate

    /// Short label for UI and previews.
    public var label: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .macAppStore: return "Mac App Store"
        case .microsoftAutoUpdate: return "Microsoft AutoUpdate"
        }
    }
}

/// Why a source's update state could not be determined.
///
/// A distinct case per cause lets the UI say *why* something is `unbekannt` and
/// — crucially — keeps every "cannot tell" outcome from ever being rendered as an
/// update. Nothing here is a claim that an update does or does not exist.
public enum UpdateUnknownReason: Hashable, Sendable {
    /// No available version could be obtained to compare against.
    case noAvailableVersion
    /// The app exposes no readable installed version.
    case noInstalledVersion
    /// Both versions are present but cannot be compared with confidence.
    case incomparableVersions
    /// A Sparkle feed could not be fetched (network/transport error).
    case feedUnreachable
    /// A Sparkle feed was fetched but produced no usable version.
    case feedUnparsable
    /// The required tool (`mas`, `msupdate`) is not installed.
    case toolUnavailable

    public var explanation: String {
        switch self {
        case .noAvailableVersion:
            return "Keine Vergleichsversion verfügbar"
        case .noInstalledVersion:
            return "Installierte Version nicht lesbar"
        case .incomparableVersions:
            return "Versionen nicht vergleichbar"
        case .feedUnreachable:
            return "Sparkle-Feed nicht erreichbar"
        case .feedUnparsable:
            return "Sparkle-Feed nicht auswertbar"
        case .toolUnavailable:
            return "Werkzeug nicht installiert"
        }
    }
}

/// The update situation of a single source, per the safety contract.
///
/// The three cases are exhaustive and never conflated: an ``unknown`` is *not*
/// an update and *not* "up to date". A false ``updateAvailable`` is the one
/// outcome the whole design works to avoid, so it is only ever produced by an
/// unambiguous version comparison.
public enum UpdateState: Hashable, Sendable {

    /// The installed version is at or ahead of the available one.
    case upToDate

    /// A newer version is available. `isMajor` marks a first-component change,
    /// which the UI and coordinator keep in a separate approval.
    case updateAvailable(available: String, isMajor: Bool)

    /// The state could not be determined; carries the reason for the UI.
    case unknown(UpdateUnknownReason)

    public var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The available version string, when one is known.
    public var availableVersion: String? {
        if case let .updateAvailable(available, _) = self { return available }
        return nil
    }

    /// Whether the available update changes the first version component.
    public var isMajor: Bool {
        if case let .updateAvailable(_, isMajor) = self { return isMajor }
        return false
    }
}

/// Identifies one update channel for an app together with the identifier its
/// backend would act on.
///
/// An app can carry several of these at once (a Homebrew cask that is also a
/// Sparkle app, a `com.microsoft.` app the store also knows); OpenFreshr keeps
/// each rather than collapsing them, so the UI can show the state *per source*.
public enum UpdateSourceKind: Hashable, Sendable {
    case homebrew(token: String)
    case macAppStore(appID: String)
    case microsoftAutoUpdate(appID: String)
    case sparkle(feedURL: String?)

    /// The backend that can drive this source, or `nil` for self-updating Sparkle.
    public var backend: UpdateBackendKind? {
        switch self {
        case .homebrew: return .homebrew
        case .macAppStore: return .macAppStore
        case .microsoftAutoUpdate: return .microsoftAutoUpdate
        case .sparkle: return nil
        }
    }

    /// The command-line identifier (cask token / adam id / MAU app id), or `nil`.
    public var identifier: String? {
        switch self {
        case let .homebrew(token): return token
        case let .macAppStore(appID): return appID
        case let .microsoftAutoUpdate(appID): return appID
        case .sparkle: return nil
        }
    }

    /// Short label for UI and logging.
    public var label: String {
        switch self {
        case let .homebrew(token): return "Homebrew: \(token)"
        case let .macAppStore(appID): return "Mac App Store (\(appID))"
        case let .microsoftAutoUpdate(appID): return "Microsoft AutoUpdate (\(appID))"
        case .sparkle: return "Sparkle"
        }
    }
}

/// One source's resolved update situation for one app.
///
/// It pairs the channel (``kind``) with its determined ``state`` and, when a
/// backend can act on it, the exact ``command`` that would run — the same
/// command the preview shows and the coordinator executes.
public struct SourceUpdate: Hashable, Sendable, Identifiable {

    /// Bundle path of the app this source belongs to.
    public var appBundlePath: String

    /// The channel and its identifier.
    public var kind: UpdateSourceKind

    /// The determined state.
    public var state: UpdateState

    /// The resolved command a backend would run, when one is available. `nil`
    /// for Sparkle (no backend) or when the backing tool is unavailable.
    public var command: ResolvedCommand?

    public init(
        appBundlePath: String,
        kind: UpdateSourceKind,
        state: UpdateState,
        command: ResolvedCommand? = nil
    ) {
        self.appBundlePath = appBundlePath
        self.kind = kind
        self.state = state
        self.command = command
    }

    public var id: String { "\(appBundlePath)|\(kind.label)" }

    /// The backend that can drive this source, if any.
    public var backend: UpdateBackendKind? { kind.backend }

    /// `true` when this source both offers an update and can actually be driven.
    public var isDrivable: Bool {
        state.hasUpdate && command != nil
    }
}

/// Everything the UI needs to show and act on one app's update status.
public struct AppUpdateReport: Sendable, Identifiable {

    public var app: InstalledApp

    /// One entry per detected source, each with its own state.
    public var sources: [SourceUpdate]

    /// `true` when the app updates itself (Sparkle framework/feed or Electron).
    ///
    /// Such apps are **display-only by default**: OpenFreshr does not drive a
    /// second updater against them in a batch. Microsoft AutoUpdate is the sole
    /// exception (it exists for exactly this), and the user may still opt in per
    /// app when a backend exists.
    public var isSelfUpdating: Bool

    public init(app: InstalledApp, sources: [SourceUpdate], isSelfUpdating: Bool) {
        self.app = app
        self.sources = sources
        self.isSelfUpdating = isSelfUpdating
    }

    public var id: String { app.bundlePath }

    /// `true` when any source reports an available update.
    public var hasUpdate: Bool { sources.contains { $0.state.hasUpdate } }

    /// `true` when any source's available update changes the major component.
    public var hasMajorUpdate: Bool { sources.contains { $0.state.isMajor } }

    /// `true` when no update source was detected at all.
    public var isUnassigned: Bool { sources.isEmpty }

    /// `true` when a source could not be determined for a reason worth flagging
    /// (a feed or tool problem, as opposed to simply lacking a version).
    public var hasSourceProblem: Bool {
        sources.contains { source in
            if case let .unknown(reason) = source.state {
                switch reason {
                case .feedUnreachable, .feedUnparsable, .toolUnavailable: return true
                case .noAvailableVersion, .noInstalledVersion, .incomparableVersions: return false
                }
            }
            return false
        }
    }

    /// The most actionable source: a drivable update wins, then any available
    /// update, then any source at all. Drives the per-app "Aktualisieren" button.
    public var primarySource: SourceUpdate? {
        sources.first(where: { $0.isDrivable })
            ?? sources.first(where: { $0.state.hasUpdate })
            ?? sources.first
    }

    /// Whether the app should be offered in the default batch selection.
    ///
    /// A drivable update that is either not self-updating or driven by Microsoft
    /// AutoUpdate qualifies; a self-updating app is withheld from the default
    /// selection (the user may still include it explicitly).
    public var isDefaultBatchSelectable: Bool {
        sources.contains { source in
            guard source.isDrivable else { return false }
            if source.backend == .microsoftAutoUpdate { return true }
            return !isSelfUpdating
        }
    }
}

/// One unit of update work: an app, the chosen backend and the exact command.
public struct UpdateItem: Sendable, Identifiable, Equatable {

    public var app: InstalledApp
    public var sourceKind: UpdateSourceKind
    public var backend: UpdateBackendKind
    public var command: ResolvedCommand
    public var targetVersion: String
    public var isMajor: Bool

    public init(
        app: InstalledApp,
        sourceKind: UpdateSourceKind,
        backend: UpdateBackendKind,
        command: ResolvedCommand,
        targetVersion: String,
        isMajor: Bool
    ) {
        self.app = app
        self.sourceKind = sourceKind
        self.backend = backend
        self.command = command
        self.targetVersion = targetVersion
        self.isMajor = isMajor
    }

    public var id: String { app.bundlePath }
}

/// A batch of update items approved together, with one invariant enforced at
/// construction: **major and regular upgrades are never mixed.**
///
/// A major upgrade (the first version component changes) can break integrations
/// and needs its own, deliberate confirmation. Making the type refuse a mixed
/// set means the coordinator can only ever be handed a batch that already
/// honours that rule — the guarantee is structural, not a convention a caller
/// might forget.
public struct UpdateRelease: Sendable {

    public let items: [UpdateItem]

    /// `true` when every item in the release is a major upgrade.
    public let isMajor: Bool

    /// Build a release, or fail when the items are empty or mix major with
    /// regular upgrades.
    public init?(items: [UpdateItem]) {
        guard let first = items.first else { return nil }
        guard items.allSatisfy({ $0.isMajor == first.isMajor }) else { return nil }
        self.items = items
        self.isMajor = first.isMajor
    }
}
