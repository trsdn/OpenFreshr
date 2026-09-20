import Foundation

/// How often OpenFreshr should scan for updates on its own.
///
/// This is a user preference, not a timer: the concrete cadence is expressed as
/// a ``duration`` and every scheduling decision is derived from *when the last
/// successful check happened*, never from a running clock. That keeps the whole
/// policy pure and testable — see ``UpdateCheckSchedule``. ``off`` is a
/// first-class value (no ``duration``) so "never check in the background" is a
/// real, persisted choice rather than the absence of a setting.
public enum UpdateCheckInterval: String, CaseIterable, Sendable, Codable, Identifiable {
    case off
    case hourly
    case daily
    case weekly

    public var id: String { rawValue }

    /// The spacing between two successful background checks, or `nil` for
    /// ``off`` — the one value that means "do not schedule a background check".
    public var duration: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3_600
        case .daily: return 86_400
        case .weekly: return 604_800
        }
    }

    /// Short, human-facing label for the settings picker and the menu bar.
    public var label: String {
        switch self {
        case .off: return "Aus"
        case .hourly: return "Stündlich"
        case .daily: return "Täglich"
        case .weekly: return "Wöchentlich"
        }
    }
}

/// The pure decision "is a background update check due right now?".
///
/// It is deliberately a value type with no clock and no storage of its own: the
/// caller passes both the last successful check and the current instant, so the
/// same logic answers for the app (real `Date`) and for a test (any injected
/// instant) without ever waiting on real time. The rule is intentionally simple
/// and honest:
///
/// - ``UpdateCheckInterval/off`` is never due.
/// - "Never checked" (a `nil` last check) with any active interval is due — a
///   fresh install should learn its update status once.
/// - Otherwise it is due once at least one ``UpdateCheckInterval/duration`` has
///   elapsed since the last success.
///
/// Because "due" is derived from a *persisted* last-check timestamp, a restart
/// does not trigger an immediate recheck: the stored time still satisfies the
/// interval until it genuinely lapses.
public struct UpdateCheckSchedule: Sendable, Equatable {

    /// The cadence this schedule enforces.
    public var interval: UpdateCheckInterval

    public init(interval: UpdateCheckInterval) {
        self.interval = interval
    }

    /// Whether a background check should run at `now`, given the last successful
    /// check (or `nil` if one has never completed).
    public func isDue(lastSuccessfulCheck: Date?, now: Date) -> Bool {
        guard let duration = interval.duration else { return false }
        guard let last = lastSuccessfulCheck else { return true }
        return now.timeIntervalSince(last) >= duration
    }

    /// The earliest instant at which a check becomes due, or `nil` when the
    /// interval is ``UpdateCheckInterval/off``. A never-checked schedule is due
    /// immediately, so this returns `now` in that case.
    public func nextCheckDate(lastSuccessfulCheck: Date?, now: Date) -> Date? {
        guard let duration = interval.duration else { return nil }
        guard let last = lastSuccessfulCheck else { return now }
        return last.addingTimeInterval(duration)
    }

    /// How long from `now` until the next check is due, clamped at zero, or `nil`
    /// when the interval is ``UpdateCheckInterval/off``. A background loop uses
    /// this to sleep only as long as necessary rather than polling on a fixed
    /// tick.
    public func secondsUntilDue(lastSuccessfulCheck: Date?, now: Date) -> TimeInterval? {
        guard let next = nextCheckDate(lastSuccessfulCheck: lastSuccessfulCheck, now: now) else {
            return nil
        }
        return max(0, next.timeIntervalSince(now))
    }
}
