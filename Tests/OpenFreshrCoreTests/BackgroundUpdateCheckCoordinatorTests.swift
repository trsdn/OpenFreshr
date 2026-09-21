import Foundation
import Testing

@testable import OpenFreshrCore

/// The coordinator that gates *when* a check may start and guarantees only one
/// runs at a time. All decisions use injected instants, so no test waits on real
/// time; the single-flight flag is asserted synchronously.
struct BackgroundUpdateCheckCoordinatorTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - due gating

    @Test
    func neverCheckedDailyIsDueAndClaimsTheSlot() {
        let coordinator = BackgroundUpdateCheckCoordinator(
            interval: .daily,
            store: InMemoryLastCheckStore()
        )
        #expect(coordinator.isCheckInProgress == false)
        #expect(coordinator.beginCheckIfDue(now: epoch) == true)
        #expect(coordinator.isCheckInProgress == true)
    }

    @Test
    func offIntervalIsNeverDueButStillForceable() {
        let coordinator = BackgroundUpdateCheckCoordinator(
            interval: .off,
            store: InMemoryLastCheckStore()
        )
        // Scheduled path: off never runs.
        #expect(coordinator.beginCheckIfDue(now: epoch) == false)
        #expect(coordinator.isCheckInProgress == false)

        // A manual "check now" is allowed even when the interval is off.
        #expect(coordinator.beginCheckIfDue(now: epoch, force: true) == true)
        #expect(coordinator.isCheckInProgress == true)
    }

    @Test
    func recentCheckIsNotDueUntilIntervalElapses() {
        let store = InMemoryLastCheckStore(lastSuccessfulCheck: epoch)
        let coordinator = BackgroundUpdateCheckCoordinator(interval: .daily, store: store)

        // 1 hour after the last check: not due.
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(3_600)) == false)
        // 25 hours after: due.
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(90_000)) == true)
    }

    // MARK: - single flight

    /// The central guarantee: while a check is in flight, neither a second
    /// scheduled check nor a forced manual one may start.
    @Test
    func aRunningCheckIsNeverDoubleStarted() {
        let coordinator = BackgroundUpdateCheckCoordinator(
            interval: .daily,
            store: InMemoryLastCheckStore()
        )

        // First claim wins.
        #expect(coordinator.beginCheckIfDue(now: epoch) == true)

        // A second scheduled attempt is refused…
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(100_000)) == false)
        // …and so is a forced manual attempt: force bypasses the schedule, never
        // the single-flight guard.
        #expect(coordinator.beginCheckIfDue(now: epoch, force: true) == false)

        // Still exactly one check in flight.
        #expect(coordinator.isCheckInProgress == true)
    }

    @Test
    func finishingSuccessfullyRecordsTheTimestampAndReleasesTheSlot() {
        let store = InMemoryLastCheckStore()
        let coordinator = BackgroundUpdateCheckCoordinator(interval: .daily, store: store)

        #expect(coordinator.beginCheckIfDue(now: epoch) == true)
        coordinator.finishCheck(success: true, at: epoch)

        #expect(coordinator.isCheckInProgress == false)
        #expect(store.lastSuccessfulCheck() == epoch)
        #expect(coordinator.lastSuccessfulCheck() == epoch)

        // Immediately after a success the daily schedule is no longer due.
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(60)) == false)
    }

    @Test
    func finishingWithoutSuccessReleasesTheSlotButKeepsItDue() {
        let store = InMemoryLastCheckStore()
        let coordinator = BackgroundUpdateCheckCoordinator(interval: .daily, store: store)

        #expect(coordinator.beginCheckIfDue(now: epoch) == true)
        coordinator.finishCheck(success: false, at: epoch)

        // No timestamp recorded, so the next attempt is due again (a failed check
        // must not look like a successful one).
        #expect(coordinator.isCheckInProgress == false)
        #expect(store.lastSuccessfulCheck() == nil)
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(60)) == true)
    }

    // MARK: - interval changes & countdown

    @Test
    func updatingTheIntervalChangesLaterDecisions() {
        let store = InMemoryLastCheckStore(lastSuccessfulCheck: epoch)
        let coordinator = BackgroundUpdateCheckCoordinator(interval: .weekly, store: store)

        // One day on, weekly is not due…
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(86_400)) == false)

        // …switch to daily and the same instant is now due.
        coordinator.updateInterval(.daily)
        #expect(coordinator.interval == .daily)
        #expect(coordinator.beginCheckIfDue(now: epoch.addingTimeInterval(86_400)) == true)
    }

    @Test
    func secondsUntilNextCheckReflectsTheStore() {
        let store = InMemoryLastCheckStore(lastSuccessfulCheck: epoch)
        let coordinator = BackgroundUpdateCheckCoordinator(interval: .hourly, store: store)
        #expect(coordinator.secondsUntilNextCheck(now: epoch.addingTimeInterval(600)) == 3_000)

        let off = BackgroundUpdateCheckCoordinator(interval: .off, store: store)
        #expect(off.secondsUntilNextCheck(now: epoch) == nil)
    }
}
