import Foundation

/// The gatekeeper that decides *when* a background check may start and guarantees
/// two never run at once.
///
/// It owns the two facts a scheduler needs and nothing else: the interval policy
/// and an in-flight flag, layered over a ``LastCheckStoring`` for the persisted
/// last-success time. The UI layer keeps the actual scanning; this type only
/// answers "start now?" and records "finished".
///
/// The single-flight guarantee is the important one. ``beginCheckIfDue(now:force:)``
/// checks the in-flight flag *first*, so even a `force`d manual "check now" is
/// refused while another check runs — a scheduled check and a manual one can
/// never overlap. It is a plain lock-guarded class (not an actor) so the flag
/// can be tested and read synchronously, and so a `@MainActor` view model can
/// consult it without hopping executors.
public final class BackgroundUpdateCheckCoordinator: @unchecked Sendable {

    private let store: LastCheckStoring
    private let lock = NSLock()
    private var isChecking = false
    private var currentInterval: UpdateCheckInterval

    public init(interval: UpdateCheckInterval, store: LastCheckStoring) {
        self.currentInterval = interval
        self.store = store
    }

    /// The cadence currently enforced. Reading is cheap and lock-guarded.
    public var interval: UpdateCheckInterval {
        lock.withLock { currentInterval }
    }

    /// Change the cadence when the user picks a different interval. Takes effect
    /// on the next scheduling decision.
    public func updateInterval(_ interval: UpdateCheckInterval) {
        lock.withLock { currentInterval = interval }
    }

    /// Whether a check is running right now.
    public var isCheckInProgress: Bool {
        lock.withLock { isChecking }
    }

    /// The persisted time of the last successful check, or `nil`.
    public func lastSuccessfulCheck() -> Date? {
        store.lastSuccessfulCheck()
    }

    /// Atomically decide whether to start a check *and* claim the in-flight slot.
    ///
    /// Returns `true` exactly once per check: the caller that gets `true` owns the
    /// check and **must** balance it with ``finishCheck(success:at:)``. Any other
    /// caller — scheduled or `force`d — gets `false` while a check is in flight,
    /// which is what prevents a manual and a background check from overlapping.
    ///
    /// - Parameters:
    ///   - now: the instant to evaluate against (injected, never read from a clock here).
    ///   - force: bypass the *schedule* (a manual "check now"), but never the
    ///     single-flight guard.
    @discardableResult
    public func beginCheckIfDue(now: Date, force: Bool = false) -> Bool {
        lock.withLock {
            if isChecking { return false }
            if !force {
                let schedule = UpdateCheckSchedule(interval: currentInterval)
                guard schedule.isDue(lastSuccessfulCheck: store.lastSuccessfulCheck(), now: now) else {
                    return false
                }
            }
            isChecking = true
            return true
        }
    }

    /// Release the in-flight slot, recording the completion time on success so the
    /// next ``beginCheckIfDue(now:force:)`` respects the interval again.
    public func finishCheck(success: Bool, at date: Date) {
        lock.withLock {
            if success {
                store.recordSuccessfulCheck(at: date)
            }
            isChecking = false
        }
    }

    /// Seconds from `now` until a scheduled check is next due, or `nil` when the
    /// interval is ``UpdateCheckInterval/off``. A background loop uses this to
    /// wait exactly as long as needed instead of polling on a fixed tick.
    public func secondsUntilNextCheck(now: Date) -> TimeInterval? {
        UpdateCheckSchedule(interval: interval)
            .secondsUntilDue(lastSuccessfulCheck: store.lastSuccessfulCheck(), now: now)
    }
}
