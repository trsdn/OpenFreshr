import Foundation

/// Where an app stands, in the terms a person cares about, not the terms of the
/// package manager behind it.
///
/// The cases answer the questions someone asks of a list of apps, in the order
/// they matter: what can OpenFreshr update for me right now, what will update
/// itself, what needs me, what can nobody tell, and what is fine.
public enum UpdateBucket: Int, CaseIterable, Comparable, Identifiable, Sendable {
    /// A newer version exists and OpenFreshr can install it with one action.
    case ready
    /// A newer version exists, but the app has its own updater. OpenFreshr does not
    /// start a second updater against it.
    case updatesItself
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
}

extension AppUpdateReport {

    /// The bucket this app belongs in. Pure, so it is the single place the
    /// grouping is decided and the window, the menu bar and a command line can
    /// never disagree about it.
    public var bucket: UpdateBucket {
        if hasUpdate {
            if isDefaultBatchSelectable { return .ready }
            // Self-updating apps come before "manual": the app will look after
            // itself, so nothing is asked of the person.
            if isSelfUpdating { return .updatesItself }
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
