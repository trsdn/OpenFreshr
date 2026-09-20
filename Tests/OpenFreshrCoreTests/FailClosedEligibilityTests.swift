import Foundation
import Testing
@testable import OpenFreshrCore

/// Focused proof of the **fail-closed** eligibility gate, on synthetic casks so
/// the exact identity conditions can be dialled in.
///
/// The real fixture happens to contain no `identityNotConfirmed` case (every
/// strong match there is either corroborated, MAS-owned, installer-only or
/// vetoed), so this behaviour — the one that blocks a strong artifact match when
/// the catalog carries **no** identity data at all — is asserted here directly.
struct FailClosedEligibilityTests {

    private func resolver(_ cask: Cask) -> MatchResolver {
        MatchResolver(index: CaskIndex(casks: [cask]))
    }

    private func app(id: String?) -> InstalledApp {
        InstalledApp(
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: id,
            shortVersion: "1.0.0",
            bundleVersion: "1.0.0"
        )
    }

    @Test
    func autoUpdatingCaskWithNoIdentityBlocksAnUncorroboratedStrongMatch() {
        // The reviewer's core scenario: a strong filename match, an auto-updating
        // cask, and *no* identity data. Fail-open would adopt; fail-closed must
        // refuse with identityNotConfirmed.
        let cask = Cask(
            token: "example",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")],
            primaryBundleIdentifiers: []
        )

        #expect(
            resolver(cask).eligibility(for: app(id: "com.example.app"))
                == .ineligible(reason: .identityNotConfirmed(caskToken: "example"))
        )
    }

    @Test
    func autoUpdatingCaskWithContradictingIdentityIsVetoedNotAdopted() {
        // Identity present but contradicting → the veto fires first.
        let cask = Cask(
            token: "example",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")],
            primaryBundleIdentifiers: ["com.someone.else"]
        )

        #expect(
            resolver(cask).eligibility(for: app(id: "com.example.app"))
                == .ineligible(reason: .strongMatchVetoed(caskToken: "example"))
        )
    }

    @Test
    func nonAutoUpdatingCaskWithNoIdentityStaysEligible() {
        // Without auto-update, Homebrew's own version check catches a wrong match
        // with a CaskError, so an uncorroborated strong match may still be offered.
        let cask = Cask(
            token: "example",
            version: "1.0.0",
            autoUpdates: false,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")],
            primaryBundleIdentifiers: []
        )

        #expect(
            resolver(cask).eligibility(for: app(id: "com.example.app"))
                == .eligible(caskToken: "example")
        )
    }

    @Test
    func corroboratedAutoUpdatingCaskIsEligible() {
        // Positive corroboration (bundle id in the cask identity) unlocks even an
        // auto-updating cask.
        let cask = Cask(
            token: "example",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")],
            primaryBundleIdentifiers: ["com.example.app"]
        )

        #expect(
            resolver(cask).eligibility(for: app(id: "com.example.app"))
                == .eligible(caskToken: "example")
        )
    }
}
