import Foundation

/// Where an app stands, in the terms a person cares about, not the terms of the
/// package manager behind it.
///
/// The cases answer the questions someone asks of a list of apps, in the order
/// they matter: what can OpenFreshr update for me right now, which apps have
/// their own updater, what needs me, what can nobody tell, and what is fine.
public enum UpdateBucket: Int, CaseIterable, Comparable, Identifiable, Sendable {
    /// A newer version exists and OpenFreshr can install it with one action.
    case ready
    /// A newer version exists and OpenFreshr cannot install it, but the app carries
    /// its own updater. That says the app *can* update; it does not say it *will*,
    /// so the person is told to open it rather than promised anything.
    case ownUpdater
    /// A newer version exists, but OpenFreshr cannot install it. The person has to
    /// do it (usually at the vendor); ``AppUpdateReport/manualReason`` says why.
    case manual
    /// No source could say whether there is an update. This is *not* "up to date".
    case cannotTell
    /// Every source that answered says the installed version is current.
    case upToDate

    public var id: Int { rawValue }

    public static func < (lhs: UpdateBucket, rhs: UpdateBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why an update that exists cannot be installed by OpenFreshr.
public enum ManualUpdateReason: Hashable, Sendable {
    /// Homebrew would have to take the app over first, and that is predicted to
    /// fail for this app. Carries the cask token.
    case homebrewCannotTakeOver(caskToken: String)
    /// No source offers a command OpenFreshr can run, for example because the
    /// backing tool is not installed.
    case noAutomaticWay

    /// A plain sentence explaining the reason — the single home for this text so
    /// the window and an AI-agent prompt (see `AIUpdateRequest`) never disagree
    /// about why OpenFreshr itself could not do this.
    public var explanation: String {
        switch self {
        case .homebrewCannotTakeOver:
            return String(localized: "Homebrew cannot take this app over.")
        case .noAutomaticWay:
            return String(localized: "No automatic way to update it.")
        }
    }
}

extension AppUpdateReport {

    /// The bucket this app belongs in. Pure, so it is the single place the
    /// grouping is decided and the window, the menu bar and a command line can
    /// never disagree about it.
    public var bucket: UpdateBucket {
        if hasUpdate {
            // Whether OpenFreshr can install it decides the group, not whether the
            // app has an updater of its own: a person who wants the Mac current
            // should not be told "leave it" about something OpenFreshr can do. An
            // app with its own updater is merely not preselected in a batch.
            if sources.contains(where: { $0.isDrivable }) { return .ready }
            if isSelfUpdating { return .ownUpdater }
            return .manual
        }
        if sources.contains(where: { $0.state == .upToDate }) { return .upToDate }
        return .cannotTell
    }

    /// Why the person has to act, for an app in ``UpdateBucket/manual``; `nil` for
    /// every other bucket.
    public var manualReason: ManualUpdateReason? {
        guard bucket == .manual else { return nil }
        if let blocked = adoptionBlockedSource, case let .adoptionWouldFail(token)? = blocked.actionBlocker {
            return .homebrewCannotTakeOver(caskToken: token)
        }
        return .noAutomaticWay
    }
}
