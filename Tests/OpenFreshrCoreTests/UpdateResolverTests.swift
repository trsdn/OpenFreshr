import Testing
@testable import OpenFreshrCore

/// Tests for the pure state mapper. It is thin, but it is where the safety rule
/// becomes a concrete ``UpdateState``, so each branch — especially every
/// `unknown` — is pinned explicitly.
struct UpdateResolverTests {

    @Test
    func strictlyOlderInstalledIsAnUpdate() {
        let state = UpdateResolver.state(installed: "1.2.3", available: "1.2.4")
        #expect(state.hasUpdate)
        #expect(state.availableVersion == "1.2.4")
        #expect(state.isMajor == false)
    }

    @Test
    func majorChangeIsFlagged() {
        let state = UpdateResolver.state(installed: "1.9.9", available: "2.0.0")
        #expect(state.hasUpdate)
        #expect(state.isMajor)
    }

    @Test
    func equalOrNewerInstalledIsUpToDate() {
        #expect(UpdateResolver.state(installed: "1.2.3", available: "1.2.3") == .upToDate)
        #expect(UpdateResolver.state(installed: "1.2.4", available: "1.2.3") == .upToDate)
    }

    @Test
    func missingInstalledVersionIsUnknownNotAnUpdate() {
        #expect(UpdateResolver.state(installed: nil, available: "1.2.3") == .unknown(.noInstalledVersion))
        #expect(UpdateResolver.state(installed: "", available: "1.2.3") == .unknown(.noInstalledVersion))
        #expect(UpdateResolver.state(installed: "   ", available: "1.2.3") == .unknown(.noInstalledVersion))
    }

    @Test
    func missingAvailableVersionIsUnknownNotAnUpdate() {
        #expect(UpdateResolver.state(installed: "1.2.3", available: nil) == .unknown(.noAvailableVersion))
        #expect(UpdateResolver.state(installed: "1.2.3", available: "") == .unknown(.noAvailableVersion))
    }

    @Test
    func incomparableVersionsAreUnknownNeverAnUpdate() {
        // The linchpin: two present-but-incomparable versions must never surface
        // as an update.
        #expect(UpdateResolver.state(installed: "1.2.3", available: "1.2.3-beta") == .unknown(.incomparableVersions))
        #expect(UpdateResolver.state(installed: "latest", available: "1.2.3") == .unknown(.incomparableVersions))
        #expect(UpdateResolver.state(installed: "1.2.3", available: ":latest") == .unknown(.incomparableVersions))
        #expect(UpdateResolver.state(installed: "nightly", available: "stable") == .unknown(.incomparableVersions))
    }

    @Test
    func noStatePassesThroughAsUpdateForAnyComparablePair() {
        // A broad sanity sweep: whenever the comparator can order a pair, the
        // resolver reflects it, and whenever it cannot, the resolver is unknown —
        // there is no fourth outcome.
        for (installed, available, expectUpdate) in [
            ("1.0.0", "1.0.1", true),
            ("1.0.1", "1.0.0", false),
            ("2026.1.1", "2026.1.2", true),
            ("5.7.3", "5.7.3,2320", false),
        ] {
            let state = UpdateResolver.state(installed: installed, available: available)
            #expect(state.hasUpdate == expectUpdate, "\(installed) -> \(available)")
            #expect(state.isUnknown == false)
        }
    }
}
