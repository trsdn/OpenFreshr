import Foundation
import Testing

@testable import OpenFreshrCore

/// The pure due-logic — evaluated entirely with injected instants, so nothing in
/// here ever waits on real time. Every interval, plus the two edge cases the
/// product hinges on ("off" and "never checked"), is asserted directly.
struct UpdateCheckScheduleTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - off

    @Test
    func offIsNeverDue() {
        let schedule = UpdateCheckSchedule(interval: .off)
        #expect(schedule.isDue(lastSuccessfulCheck: nil, now: epoch) == false)
        #expect(schedule.isDue(lastSuccessfulCheck: epoch, now: epoch.addingTimeInterval(10 * 604_800)) == false)
        #expect(schedule.nextCheckDate(lastSuccessfulCheck: nil, now: epoch) == nil)
        #expect(schedule.secondsUntilDue(lastSuccessfulCheck: nil, now: epoch) == nil)
    }

    // MARK: - never checked

    @Test(arguments: [UpdateCheckInterval.hourly, .daily, .weekly])
    func neverCheckedIsDueForEveryActiveInterval(_ interval: UpdateCheckInterval) {
        let schedule = UpdateCheckSchedule(interval: interval)
        #expect(schedule.isDue(lastSuccessfulCheck: nil, now: epoch) == true)
        // A never-checked schedule wants to run "now".
        #expect(schedule.nextCheckDate(lastSuccessfulCheck: nil, now: epoch) == epoch)
        #expect(schedule.secondsUntilDue(lastSuccessfulCheck: nil, now: epoch) == 0)
    }

    // MARK: - elapsed vs not-yet-elapsed, per interval

    @Test(arguments: [
        UpdateCheckInterval.hourly,
        .daily,
        .weekly,
    ])
    func dueOnlyAfterOneFullInterval(_ interval: UpdateCheckInterval) throws {
        let duration = try #require(interval.duration)
        let schedule = UpdateCheckSchedule(interval: interval)

        // One second short of the interval: not due.
        #expect(
            schedule.isDue(
                lastSuccessfulCheck: epoch,
                now: epoch.addingTimeInterval(duration - 1)
            ) == false)

        // Exactly at the interval: due (>= boundary is inclusive).
        #expect(
            schedule.isDue(
                lastSuccessfulCheck: epoch,
                now: epoch.addingTimeInterval(duration)
            ) == true)

        // Well past the interval: due.
        #expect(
            schedule.isDue(
                lastSuccessfulCheck: epoch,
                now: epoch.addingTimeInterval(duration * 3)
            ) == true)
    }

    @Test
    func nextCheckDateIsLastPlusInterval() throws {
        let schedule = UpdateCheckSchedule(interval: .daily)
        let next = try #require(schedule.nextCheckDate(lastSuccessfulCheck: epoch, now: epoch))
        #expect(next == epoch.addingTimeInterval(86_400))
    }

    @Test
    func secondsUntilDueCountsDownAndClampsAtZero() {
        let schedule = UpdateCheckSchedule(interval: .hourly)
        // 15 minutes after a check: 45 minutes remain.
        #expect(
            schedule.secondsUntilDue(
                lastSuccessfulCheck: epoch,
                now: epoch.addingTimeInterval(900)
            ) == 2_700)
        // Long past due: clamped to zero rather than negative.
        #expect(
            schedule.secondsUntilDue(
                lastSuccessfulCheck: epoch,
                now: epoch.addingTimeInterval(10_000)
            ) == 0)
    }
}
