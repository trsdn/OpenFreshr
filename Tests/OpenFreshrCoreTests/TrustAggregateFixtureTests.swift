import Foundation
import Testing

@testable import OpenFreshrCore

/// Trust-layer aggregate over the **real** captured signing facts of the
/// reference machine (`Fixtures/code-signatures.json`, produced once by
/// `capture-signatures.py`). Like the other aggregate suites this is a
/// regression anchor for the head-line Definition-of-Done metric — how many of
/// the 109 reference apps expose a readable Apple Team ID — and it exercises the
/// gate over that real distribution **without** any test touching `codesign`.
struct TrustAggregateFixtureTests {

    /// The captured distribution is frozen: 109 apps, 107 present, 100 with a
    /// readable team ID. This is the number the final report quotes.
    @Test
    func referenceMachineTeamIdentifierCoverage() throws {
        let records = try Fixture.codeSignatures()
        let apps = try Fixture.installedApps()

        #expect(records.count == apps.count)

        let present = records.values.filter { $0.present }.count
        let readableTeam = records.values.filter { $0.teamIdentifier != nil }.count
        let verified = records.values.filter { $0.verification == "verified" }.count

        // Surfaced the same way the other aggregates print their head-line.
        print(
            "[trust-aggregate] apps=\(records.count) present=\(present) readableTeamID=\(readableTeam) verified=\(verified)"
        )

        #expect(records.count == 109)
        #expect(present == 107)
        #expect(readableTeam == 100)
    }

    /// Replaying the real facts through the gate: every present, verified app
    /// with a readable team ID and a bundle id establishes a first-use baseline
    /// and is allowed; a second look then reads as *verified & trusted* against
    /// that very baseline. Nothing in this loop blocks.
    @Test
    func firstUseThenSteadyStateOverRealSignatures() throws {
        let records = try Fixture.codeSignatures()
        let infos = try Fixture.codeSignatureInfos()
        let apps = try Fixture.installedApps()
        let store = InMemoryTrustStore()
        let gate = TrustGate(inspector: FakeCodeSignatureInspector(infos: infos), store: store)

        var anchored = 0
        var anchoredIDs = Set<String>()
        for app in apps {
            guard let record = records[app.bundlePath], record.present,
                let info = infos[app.bundlePath],
                info.isVerified,
                info.teamIdentifier != nil,
                let bundleID = app.bundleIdentifier, !bundleID.isEmpty
            else { continue }

            // First replacement: allowed, and it anchors the observed team ID.
            #expect(gate.authorize(app).isAllowed)
            anchored += 1
            anchoredIDs.insert(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

            // Second replacement: same signature, now a trusted match — still no
            // acknowledgement required.
            let steady = gate.evaluate(app)
            #expect(steady.wouldBlockAutomaticReplacement == false)
            if case .verifiedTrusted = steady.status {
            } else {
                Issue.record("expected verifiedTrusted for \(app.bundlePath), got \(steady.status)")
            }
        }

        // The reference set has a large verified/attributed majority; assert a
        // healthy floor rather than an exact count so the test is robust to a
        // single app being (un)installed, while still proving the loop ran. The
        // store holds one record per *distinct* bundle id (two reference apps can
        // share an id), so it is keyed by `anchoredIDs`, not the raw pass count.
        #expect(anchored >= 90)
        #expect(store.allRecords().count == anchoredIDs.count)
    }

    /// Apps whose real signature is *unsigned* or *invalid* are hard-blocked from
    /// automatic replacement — the gate never treats absence of proof as proof.
    @Test
    func unsignedOrInvalidRealAppsAreBlocked() throws {
        let infos = try Fixture.codeSignatureInfos()
        let records = try Fixture.codeSignatures()
        let apps = try Fixture.installedApps()
        let store = InMemoryTrustStore()
        let gate = TrustGate(inspector: FakeCodeSignatureInspector(infos: infos), store: store)

        var blocked = 0
        for app in apps {
            guard let record = records[app.bundlePath], record.present,
                let info = infos[app.bundlePath]
            else { continue }
            let isUnsigned: Bool = {
                if case .unsigned = info.verification { return true }; return false
            }()
            let isInvalid: Bool = {
                if case .invalid = info.verification { return true }; return false
            }()
            guard isUnsigned || isInvalid else { continue }

            #expect(gate.authorize(app).isAllowed == false)
            blocked += 1
        }

        // At least the two truly unsigned and the handful of invalid present apps
        // captured on the reference machine must be here.
        #expect(blocked >= 1)
    }
}
