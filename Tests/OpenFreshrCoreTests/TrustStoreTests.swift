import Foundation
import Testing

@testable import OpenFreshrCore

/// The on-disk ``JSONFileTrustStore`` — the app's real persistence. Exercised
/// against a throwaway file under the package's own `.build` sandbox (never
/// `/tmp`, never the user's Application Support), cleaned up in `defer`.
struct TrustStoreTests {

    /// A fresh URL under `.build/trust-store-tests/` unique per test.
    private func scratchURL(_ name: String) -> URL {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenFreshrCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent(".build/trust-store-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(name)-\(UUID().uuidString).json", isDirectory: false)
    }

    @Test
    func recordsSurviveAReloadFromDisk() throws {
        let url = scratchURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url) }

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = JSONFileTrustStore(url: url)
            store.save(
                TrustRecord(
                    bundleIdentifier: "com.figma.desktop",
                    teamIdentifier: "T1234ABCDE",
                    firstObservedAt: epoch,
                    updatedAt: epoch,
                    origin: .firstUse
                ))
            store.save(
                TrustRecord(
                    bundleIdentifier: "com.google.chrome",
                    teamIdentifier: "EQHXZ8M8AV",
                    firstObservedAt: epoch,
                    updatedAt: epoch,
                    origin: .userConfirmedChange,
                    confirmedChanges: [
                        TrustChange(
                            previousTeamIdentifier: "OLDTEAM111",
                            newTeamIdentifier: "EQHXZ8M8AV",
                            confirmedAt: epoch
                        )
                    ]
                ))
        }

        // A brand-new instance must see exactly what was written, audit trail included.
        let reloaded = JSONFileTrustStore(url: url)
        #expect(reloaded.allRecords().count == 2)

        let figma = try #require(reloaded.record(for: "com.figma.desktop"))
        #expect(figma.teamIdentifier == "T1234ABCDE")
        #expect(figma.origin == .firstUse)

        let chrome = try #require(reloaded.record(for: "com.google.chrome"))
        #expect(chrome.origin == .userConfirmedChange)
        #expect(chrome.confirmedChanges.count == 1)
        #expect(chrome.confirmedChanges.first?.previousTeamIdentifier == "OLDTEAM111")
    }

    @Test
    func resetRemovesOneRecordAndResetAllClears() throws {
        let url = scratchURL("reset")
        defer { try? FileManager.default.removeItem(at: url) }

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let store = JSONFileTrustStore(url: url)
        store.save(
            TrustRecord(
                bundleIdentifier: "com.a.one", teamIdentifier: "AAAA111111",
                firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse))
        store.save(
            TrustRecord(
                bundleIdentifier: "com.b.two", teamIdentifier: "BBBB222222",
                firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse))

        store.reset(bundleIdentifier: "com.a.one")
        #expect(store.record(for: "com.a.one") == nil)
        #expect(store.record(for: "com.b.two") != nil)
        // Removal is durable across reloads.
        #expect(JSONFileTrustStore(url: url).allRecords().count == 1)

        store.resetAll()
        #expect(store.allRecords().isEmpty)
        #expect(JSONFileTrustStore(url: url).allRecords().isEmpty)
    }

    @Test
    func aCorruptFileStartsEmptyRatherThanCrashing() throws {
        let url = scratchURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("this is not json".utf8).write(to: url)

        let store = JSONFileTrustStore(url: url)
        #expect(store.allRecords().isEmpty)

        // And it can recover to a working store.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(
            TrustRecord(
                bundleIdentifier: "com.c.three", teamIdentifier: "CCCC333333",
                firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse))
        #expect(JSONFileTrustStore(url: url).record(for: "com.c.three") != nil)
    }
}
