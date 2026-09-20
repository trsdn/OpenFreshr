import Foundation

/// The read-only summary the menu bar shows: how many updates are available,
/// when OpenFreshr last checked, on what cadence, and whether a check is running.
///
/// It exists so the menu bar is unambiguously a *status* surface. The count is
/// derived by one function — ``availableUpdateCount(in:)`` — which is the single
/// definition of "an available update" shared with the window's "Updates" list,
/// so the two can never disagree. The menu bar never carries an action that
/// bypasses the trust gate or the preview; it reports, and hands off to the
/// window for anything that changes an app.
public struct MenuBarStatus: Sendable, Equatable {

    /// Number of apps with at least one available update.
    public var availableUpdateCount: Int

    /// When the last background (or manual) check completed, or `nil` if none has.
    public var lastSuccessfulCheck: Date?

    /// The cadence currently configured.
    public var interval: UpdateCheckInterval

    /// Whether a check is running right now.
    public var isChecking: Bool

    public init(
        availableUpdateCount: Int,
        lastSuccessfulCheck: Date? = nil,
        interval: UpdateCheckInterval = .daily,
        isChecking: Bool = false
    ) {
        self.availableUpdateCount = availableUpdateCount
        self.lastSuccessfulCheck = lastSuccessfulCheck
        self.interval = interval
        self.isChecking = isChecking
    }

    /// `true` when at least one update is available.
    public var hasUpdates: Bool {
        availableUpdateCount > 0
    }

    /// The one definition of "how many updates are available", over a set of
    /// per-app reports.
    ///
    /// It counts apps whose report has an available update
    /// (``AppUpdateReport/hasUpdate``) — exactly the predicate the window's
    /// "Updates" filter uses. The menu bar and the window both route their count
    /// through this function (directly, or via the view model's `Updates` filter
    /// which shares the same predicate), so the badge and the list always match.
    public static func availableUpdateCount(in reports: [AppUpdateReport]) -> Int {
        reports.reduce(into: 0) { total, report in
            total += report.hasUpdate ? 1 : 0
        }
    }
}
