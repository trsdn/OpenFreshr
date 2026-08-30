import Foundation
import Testing
@testable import OpenFreshrCore

/// Trust-on-first-use policy, exercised entirely through fakes: an
/// ``InMemoryTrustStore`` and a ``FakeCodeSignatureInspector``. No disk, no real
/// signing tools. Proves the store-first-observation / same-team-passes /
/// changed-team-blocks / opt-in-logs / reset cycle the spec calls out by name.
struct TrustGateTests {

    private func app(_ path: String = "/Applications/Figma.app",
                     id: String? = "com.figma.Desktop") -> InstalledApp {
        InstalledApp(bundlePath: path, bundleIdentifier: id)
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - First use

    @Test
    func firstObservationRecordsBaselineAndAllows() {
        let store = InMemoryTrustStore()
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "T1234ABCDE"), store: store)

        let decision = gate.authorize(app(), now: epoch)

        #expect(decision == .allowed)
        // The key is the normalised (lower-cased) bundle identifier.
        let record = store.record(for: "com.figma.desktop")
        #expect(record?.teamIdentifier == "T1234ABCDE")
        #expect(record?.origin == .firstUse)
        #expect(record?.confirmedChanges.isEmpty == true)
    }

    @Test
    func firstUseWithoutReadableTeamAllowsButAnchorsNothing() {
        // A verified Apple app with `TeamIdentifier=not set` → nil team.
        let store = InMemoryTrustStore()
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Safari.app", team: nil), store: store)

        let decision = gate.authorize(app("/Applications/Safari.app", id: "com.apple.Safari"), now: epoch)

        #expect(decision == .allowed)
        #expect(store.record(for: "com.apple.safari") == nil)
    }

    // MARK: - Same team

    @Test
    func sameTeamPasses() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "T1234ABCDE",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "T1234ABCDE"), store: store)

        #expect(gate.authorize(app(), now: epoch) == .allowed)
        // Baseline is unchanged.
        #expect(store.record(for: "com.figma.desktop")?.origin == .firstUse)
    }

    // MARK: - Changed team

    @Test
    func changedTeamBlocksWithoutOptIn() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "NEWTEAM222"), store: store)

        let decision = gate.authorize(app(), acknowledgeTeamChange: false, now: epoch)

        guard case let .blocked(.teamIdentifierChanged(change)) = decision else {
            Issue.record("expected a team-change block, got \(decision)")
            return
        }
        #expect(change.previousTeamIdentifier == "OLDTEAM111")
        #expect(change.newTeamIdentifier == "NEWTEAM222")
        // The baseline must NOT advance on a blocked (un-acknowledged) change.
        #expect(store.record(for: "com.figma.desktop")?.teamIdentifier == "OLDTEAM111")
    }

    @Test
    func changedTeamWithOptInAllowsAdvancesBaselineAndLogsChange() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "NEWTEAM222"), store: store)
        let later = epoch.addingTimeInterval(3600)

        let decision = gate.authorize(app(), acknowledgeTeamChange: true, now: later)

        #expect(decision == .allowed)
        let record = store.record(for: "com.figma.desktop")
        #expect(record?.teamIdentifier == "NEWTEAM222")
        #expect(record?.origin == .userConfirmedChange)
        #expect(record?.firstObservedAt == epoch)          // first-observed preserved
        #expect(record?.updatedAt == later)
        #expect(record?.confirmedChanges.count == 1)
        #expect(record?.confirmedChanges.first?.previousTeamIdentifier == "OLDTEAM111")
        #expect(record?.confirmedChanges.first?.newTeamIdentifier == "NEWTEAM222")
    }

    // MARK: - Reset

    @Test
    func resetMakesNextObservationAFreshFirstUseNotImplicitReTrust() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "NEWTEAM222"), store: store)

        gate.resetTrust(bundleIdentifier: "com.figma.Desktop")   // pass raw id; gate normalises
        #expect(store.record(for: "com.figma.desktop") == nil)

        // The previously-diverging team now records cleanly as a new baseline,
        // rather than the old team being implicitly re-trusted.
        let decision = gate.authorize(app(), now: epoch)
        #expect(decision == .allowed)
        #expect(store.record(for: "com.figma.desktop")?.teamIdentifier == "NEWTEAM222")
    }

    @Test
    func resetAllForgetsEveryDecision() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.a.app", teamIdentifier: "AAA",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse),
            TrustRecord(bundleIdentifier: "com.b.app", teamIdentifier: "BBB",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector(infos: [:]), store: store)

        gate.resetAllTrust()

        #expect(gate.storedRecords().isEmpty)
    }

    // MARK: - Signature / Gatekeeper blocks

    @Test
    func unsignedBundleBlocks() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector(infos: [
                "/Applications/Foo.app": CodeSignatureInfo(
                    teamIdentifier: nil, verification: .unsigned, gatekeeper: .rejected("x"))
            ]),
            store: InMemoryTrustStore())

        #expect(gate.authorize(app("/Applications/Foo.app", id: "com.foo.app")) == .blocked(.unsigned))
    }

    @Test
    func invalidSignatureBlocks() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector(infos: [
                "/Applications/Foo.app": CodeSignatureInfo(
                    teamIdentifier: "T", verification: .invalid("bad"), gatekeeper: .accepted)
            ]),
            store: InMemoryTrustStore())

        #expect(gate.authorize(app("/Applications/Foo.app", id: "com.foo.app")) == .blocked(.signatureInvalid("bad")))
    }

    @Test
    func gatekeeperRejectionBlocks() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector(infos: [
                "/Applications/Foo.app": CodeSignatureInfo(
                    teamIdentifier: "T", verification: .verified, gatekeeper: .rejected("nope"))
            ]),
            store: InMemoryTrustStore())

        #expect(gate.authorize(app("/Applications/Foo.app", id: "com.foo.app")) == .blocked(.gatekeeperRejected("nope")))
    }

    @Test
    func unreadableIdentityBlocks() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector.verified("/Applications/Foo.app", team: "T"),
            store: InMemoryTrustStore())

        #expect(gate.authorize(app("/Applications/Foo.app", id: nil)) == .blocked(.identityUnreadable))
    }

    // MARK: - Degradation (missing tool)

    @Test
    func missingSignatureToolDegradesRatherThanBlocks() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector(infos: [
                "/Applications/Foo.app": CodeSignatureInfo(
                    teamIdentifier: nil, verification: .toolUnavailable, gatekeeper: .toolUnavailable)
            ]),
            store: InMemoryTrustStore())

        #expect(gate.authorize(app("/Applications/Foo.app", id: "com.foo.app"))
                == .allowedWithoutVerification(.signatureToolUnavailable))
    }

    @Test
    func baselineWithUnreadableCurrentTeamDegrades() {
        // Verified now, but the current team is unreadable while a baseline exists:
        // the comparison cannot run, so degrade instead of passing or blocking.
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.foo.app", teamIdentifier: "T",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Foo.app", team: nil), store: store)

        #expect(gate.authorize(app("/Applications/Foo.app", id: "com.foo.app"))
                == .allowedWithoutVerification(.teamIdentifierUnreadable))
    }

    // MARK: - Read-only evaluation never mutates

    @Test
    func evaluateDoesNotRecordBaseline() {
        let store = InMemoryTrustStore()
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "T1234ABCDE"), store: store)

        let evaluation = gate.evaluate(app())

        #expect(evaluation.status == .firstUse(teamIdentifier: "T1234ABCDE"))
        #expect(evaluation.wouldBlockAutomaticReplacement == false)
        // Looking must not anchor anything.
        #expect(store.allRecords().isEmpty)
    }

    @Test
    func evaluateSurfacesPendingTeamChange() {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified("/Applications/Figma.app", team: "NEWTEAM222"), store: store)

        let evaluation = gate.evaluate(app())

        #expect(evaluation.wouldBlockAutomaticReplacement)
        #expect(evaluation.pendingTeamChange?.previousTeamIdentifier == "OLDTEAM111")
        #expect(evaluation.pendingTeamChange?.newTeamIdentifier == "NEWTEAM222")
    }
}
