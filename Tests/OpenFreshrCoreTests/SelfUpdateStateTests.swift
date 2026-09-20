import Foundation
import Testing

@testable import OpenFreshrCore

@Suite("SelfUpdateSchedule")
struct SelfUpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Disabled never checks, even when overdue")
    func disabled() {
        #expect(!SelfUpdateSchedule.isDue(enabled: false, lastCheck: nil, now: now))
    }

    @Test("A first launch with no history is due")
    func neverChecked() {
        #expect(SelfUpdateSchedule.isDue(enabled: true, lastCheck: nil, now: now))
    }

    @Test("Due only once a full interval has passed")
    func interval() {
        let justUnder = now.addingTimeInterval(-(SelfUpdateSchedule.checkInterval - 1))
        let exactly = now.addingTimeInterval(-SelfUpdateSchedule.checkInterval)
        #expect(!SelfUpdateSchedule.isDue(enabled: true, lastCheck: justUnder, now: now))
        #expect(SelfUpdateSchedule.isDue(enabled: true, lastCheck: exactly, now: now))
    }

    @Test("A last check in the future means the clock moved back, so it is due")
    func clockMovedBack() {
        let future = now.addingTimeInterval(3_600)
        #expect(SelfUpdateSchedule.isDue(enabled: true, lastCheck: future, now: now))
    }
}

@Suite("SelfUpdateState")
struct SelfUpdateStateTests {
    @Test("Only in-flight states are busy")
    func busy() {
        #expect(SelfUpdateState.checking.isBusy)
        #expect(SelfUpdateState.downloading(version: "1.1.0").isBusy)
        #expect(SelfUpdateState.installing.isBusy)
        #expect(!SelfUpdateState.idle.isBusy)
        #expect(!SelfUpdateState.readyToInstall(version: "1.1.0").isBusy)
        #expect(!SelfUpdateState.installFailed("x").isBusy)
    }

    @Test("Ready to install is reported only for a downloaded update")
    func ready() {
        #expect(SelfUpdateState.readyToInstall(version: "1.1.0").isReadyToInstall)
        #expect(!SelfUpdateState.downloading(version: "1.1.0").isReadyToInstall)
    }

    @Test("A background failure or no-update stays silent; a manual one answers")
    func silentInBackground() {
        #expect(SelfUpdateState.afterFailure("offline", userInitiated: false) == .idle)
        #expect(SelfUpdateState.afterFailure("offline", userInitiated: true) == .failed("offline"))
        #expect(SelfUpdateState.afterNoUpdate(userInitiated: false) == .idle)
        #expect(SelfUpdateState.afterNoUpdate(userInitiated: true) == .upToDate)
    }
}
