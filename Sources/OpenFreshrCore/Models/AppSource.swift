import Foundation

/// One update/distribution channel an app can belong to.
///
/// An app frequently belongs to **several** sources at once — a Homebrew cask
/// that is also a Sparkle app, or a `com.microsoft.` app that Homebrew knows and
/// Microsoft AutoUpdate services. OpenFreshr keeps every source instead of
/// collapsing them behind one global priority, because the conflict itself is
/// information the user needs. A set of these values is therefore the natural
/// carrier for an app's provenance.
public enum AppSource: Hashable, Sendable {

    /// Installed from the Mac App Store (a `_MASReceipt` was found).
    case macAppStore

    /// Ships a Sparkle feed URL; the associated value carries it verbatim.
    case sparkle(feedURL: String?)

    /// Ships the Sparkle framework but exposes no readable feed.
    case sparkleRuntime

    /// Serviced by Microsoft AutoUpdate (`com.microsoft.` namespace).
    case microsoftAutoUpdate

    /// Serviced by Apple's `softwareupdate` (`com.apple.` namespace).
    case appleSoftwareUpdate

    /// Known to Homebrew as a cask. The strength distinguishes a confident
    /// artifact match from a mere bundle-id/name suggestion, and the flag records
    /// whether the cask is already installed and managing the app.
    case homebrew(token: String, strength: MatchStrength, managed: Bool)

    /// Short, stable label for UI and logging.
    public var label: String {
        switch self {
        case .macAppStore: return "Mac App Store"
        case .sparkle: return "Sparkle"
        case .sparkleRuntime: return "Sparkle (Feed unbekannt)"
        case .microsoftAutoUpdate: return "Microsoft AutoUpdate"
        case .appleSoftwareUpdate: return "Apple Software Update"
        case let .homebrew(token, strength, managed):
            let suffix = managed ? " (verwaltet)" : (strength == .weak ? " (Vorschlag)" : "")
            return "Homebrew: \(token)\(suffix)"
        }
    }

    /// `true` for a source that already actively manages the app's updates.
    ///
    /// Used to reason about conflicts: two managing sources on one app is the
    /// situation adoption must avoid creating.
    public var isManaging: Bool {
        switch self {
        case .macAppStore, .microsoftAutoUpdate, .appleSoftwareUpdate:
            return true
        case let .homebrew(_, _, managed):
            return managed
        case .sparkle, .sparkleRuntime:
            // Self-updating, but OpenFreshr never drives it in phase 1; it is a
            // visible hint, not a manager OpenFreshr competes with.
            return false
        }
    }
}
