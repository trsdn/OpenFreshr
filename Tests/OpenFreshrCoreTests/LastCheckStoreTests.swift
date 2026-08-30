import Foundation
import Testing
@testable import OpenFreshrCore

/// The last-check persistence, both doubles. The decisive test is
/// ``persistedTimestampPreventsImmediateRecheckAfterRestart``: it proves that a
/// value written to disk, then read back by a brand-new store instance (a
/// "restart"), still satisfies the interval so no check fires on launch.
struct LastCheckStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fresh URL under `.build/last-check-tests/` unique per test — never
    /// `/tmp`, never the user's real Application Support.
    private func scratchURL(_ name: String) -> URL {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OpenFreshrCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent(".build/last-check-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(name)-\(UUID().uuidString).json", isDirectory: false)
    }

    // MARK: - in-memory

    @Test
    func inMemoryStoreSeedsRecordsAndClears() {
        let store = InMemoryLastCheckStore(lastSuccessfulCheck: epoch)
        #expect(store.lastSuccessfulCheck() == epoch)

        let later = epoch.addingTimeInterval(3_600)
        store.recordSuccessfulCheck(at: later)
        #expect(store.lastSuccessfulCheck() == later)

        store.clear()
        #expect(store.lastSuccessfulCheck() == nil)
    }

    @Test
    func inMemoryStoreDefaultsToNeverChecked() {
        #expect(InMemoryLastCheckStore().lastSuccessfulCheck() == nil)
    }

    // MARK: - JSON file

    @Test
    func timestampSurvivesAReloadFromDisk() throws {
        let url = scratchURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = JSONFileLastCheckStore(url: url)
            store.recordSuccessfulCheck(at: epoch)
        }

        let reloaded = JSONFileLastCheckStore(url: url)
        let restored = try #require(reloaded.lastSuccessfulCheck())
        // ISO-8601 encoding is second-resolution; compare at that granularity.
        #expect(abs(restored.timeIntervalSince(epoch)) < 1)
    }

    @Test
    func missingFileReadsAsNeverChecked() {
        let url = scratchURL("absent")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(JSONFileLastCheckStore(url: url).lastSuccessfulCheck() == nil)
    }

    @Test
    func clearErasesTheStoredTimestampOnDisk() throws {
        let url = scratchURL("clear")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONFileLastCheckStore(url: url)
        store.recordSuccessfulCheck(at: epoch)
        store.clear()

        // A fresh instance must also see it gone, i.e. the clear was persisted.
        #expect(JSONFileLastCheckStore(url: url).lastSuccessfulCheck() == nil)
    }

    /// The core anti-thrash guarantee: after a "restart" (a new store reading the
    /// same file) a daily schedule evaluated shortly afterwards is **not** due.
    @Test
    func persistedTimestampPreventsImmediateRecheckAfterRestart() throws {
        let url = scratchURL("restart")
        defer { try? FileManager.default.removeItem(at: url) }

        // First run records a successful check.
        do {
            JSONFileLastCheckStore(url: url).recordSuccessfulCheck(at: epoch)
        }

        // "Restart": a new store instance loads the persisted timestamp.
        let reloaded = JSONFileLastCheckStore(url: url)
        let schedule = UpdateCheckSchedule(interval: .daily)

        // One minute after launch — the day has not elapsed, so no check is due.
        #expect(schedule.isDue(
            lastSuccessfulCheck: reloaded.lastSuccessfulCheck(),
            now: epoch.addingTimeInterval(60)
        ) == false)

        // A full day later it becomes due again.
        #expect(schedule.isDue(
            lastSuccessfulCheck: reloaded.lastSuccessfulCheck(),
            now: epoch.addingTimeInterval(86_400)
        ) == true)
    }
}
