import Testing
@testable import OpenFreshrCore

/// The security core of OpenFreshr: matching, the veto rule and adoption
/// eligibility, driven by the real coverage-derived fixtures.
struct MatchResolverTests {

    private func resolver(managed: Set<String> = []) throws -> MatchResolver {
        let index = CaskIndex(casks: try Fixture.casks())
        return MatchResolver(index: index, managedTokens: managed)
    }

    // MARK: - Mandatory table-driven regression over ALL four mismatches

    /// One row of the mismatch regression table.
    struct MismatchCase: Sendable {
        /// Bundle file name of the installed app, e.g. `Copilot.app`.
        let appBundleName: String
        /// The *wrong* cask that must never be allowed to adopt this app.
        let wrongToken: String
        /// `true` when the wrong cask produces a **strong** artifact match that
        /// the veto has to revoke (the Copilot case); `false` when the match is
        /// only ever a weak cleanup-stanza suggestion.
        let strongArtifactButVetoed: Bool
    }

    /// The four verified real-world traps. A single Copilot test would not
    /// protect the other three, so they are exercised as one table.
    static let mismatches: [MismatchCase] = [
        // Strong artifact match (Copilot.app == copilot-money's `Copilot.app`),
        // neutralised only by the veto rule.
        MismatchCase(appBundleName: "Copilot.app", wrongToken: "copilot-money",
                     strongArtifactButVetoed: true),
        // Weak cleanup-stanza suggestions from a suite/agent cask.
        MismatchCase(appBundleName: "Microsoft Defender.app", wrongToken: "microsoft-office",
                     strongArtifactButVetoed: false),
        MismatchCase(appBundleName: "OneDrive.app", wrongToken: "microsoft-office",
                     strongArtifactButVetoed: false),
        MismatchCase(appBundleName: "DisplayLink Manager.app", wrongToken: "elgato-camera-hub",
                     strongArtifactButVetoed: false),
    ]

    @Test(arguments: mismatches)
    func wrongCaskIsNeutralisedAndNeverAdoptable(_ testCase: MismatchCase) throws {
        let apps = try Fixture.installedApps()
        let resolver = try resolver()
        let app = try #require(Fixture.app(named: testCase.appBundleName, in: apps))

        let matches = resolver.matches(for: app)
        let wrong = try #require(
            matches.first { $0.caskToken == testCase.wrongToken },
            "expected the wrong cask \(testCase.wrongToken) to appear as a candidate"
        )

        // Whatever the evidence, the effective strength is weak: a weak match can
        // never authorise adoption.
        #expect(wrong.strength == .weak)

        if testCase.strongArtifactButVetoed {
            // The dangerous case: a real app-artifact match, demoted by the veto.
            #expect(wrong.vetoed == true)
            if case .appArtifact = wrong.reason {} else {
                Issue.record("expected an appArtifact reason for \(testCase.appBundleName)")
            }
        } else {
            // The suite-cleanup case: a weak bundle-id suggestion, no veto needed.
            #expect(wrong.vetoed == false)
            if case .bundleIdentifierInStanza = wrong.reason {} else {
                Issue.record("expected a bundleIdentifierInStanza reason for \(testCase.appBundleName)")
            }
        }

        // The invariant that actually protects the user: the app is never
        // eligible to be adopted as the wrong cask.
        let eligibility = resolver.eligibility(for: app, matches: matches)
        #expect(eligibility.isEligible == false)
        #expect(eligibility.caskToken != testCase.wrongToken)
    }

    // MARK: - The veto alone blocks Copilot (independent of the MAS receipt)

    @Test
    func copilotWithoutMASReceiptIsBlockedByVetoAlone() throws {
        let apps = try Fixture.installedApps()
        let resolver = try resolver()
        var copilot = try #require(Fixture.app(named: "Copilot.app", in: apps))

        // Strip the Mac App Store receipt so the *only* thing standing between
        // Microsoft Copilot and the copilot-money finance app is the veto rule.
        copilot.hasMacAppStoreReceipt = false

        #expect(
            resolver.eligibility(for: copilot)
                == .ineligible(reason: .strongMatchVetoed(caskToken: "copilot-money"))
        )
    }

    // MARK: - Positive controls: real apps that SHOULD be adoptable

    @Test
    func onePasswordIsEligibleForItsOwnCask() throws {
        let apps = try Fixture.installedApps()
        let resolver = try resolver()
        let app = try #require(Fixture.app(named: "1Password.app", in: apps))

        #expect(resolver.eligibility(for: app) == .eligible(caskToken: "1password"))
    }

    @Test
    func githubCopilotIsEligibleAndDistinctFromMicrosoftCopilot() throws {
        let apps = try Fixture.installedApps()
        let resolver = try resolver()
        let app = try #require(Fixture.app(named: "GitHub Copilot.app", in: apps))

        #expect(resolver.eligibility(for: app) == .eligible(caskToken: "github-copilot-app"))
    }

    // MARK: - Bucket separation: strong identity vs. path-derived cleanup ids

    @Test
    func aStrongFieldCaskIsNotCorroboratedViaACleanupPath() {
        // The cask declares a *strong* identity (a foreign helper) and, only in a
        // cleanup path, the installed app's own id. Because a strong identity is
        // present, the path id must NOT corroborate — and since the cask
        // auto-updates, the uncorroborated strong match is refused rather than
        // silently offered.
        let cask = Cask(
            token: "suspicious",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Target.app")],
            primaryBundleIdentifiers: ["com.foreign.helper"],
            cleanupBundleIdentifiers: ["com.target.app"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Target.app",
            bundleIdentifier: "com.target.app"
        )

        // The id *is* in the union, so the match is not vetoed — but it is not
        // corroborated either, so an auto-updating cask stays unconfirmed.
        #expect(
            resolver.eligibility(for: app)
                == .ineligible(reason: .identityNotConfirmed(caskToken: "suspicious"))
        )
    }

    @Test
    func aCaskWithoutStrongFieldsIsCorroboratedViaACleanupPath() {
        // Mirror image: no strong identity at all, so the path-derived id is
        // allowed to stand in as a fallback. That corroboration is exactly what
        // lets the many zap-only casks (VLC, Obsidian, …) be adopted.
        let cask = Cask(
            token: "cleanup-only",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Target.app")],
            primaryBundleIdentifiers: [],
            cleanupBundleIdentifiers: ["com.target.app"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Target.app",
            bundleIdentifier: "com.target.app"
        )

        #expect(resolver.eligibility(for: app) == .eligible(caskToken: "cleanup-only"))
    }

    @Test
    func aCleanupPathIdStillVetoesAContradictoryApp() {
        // A path-derived id is not proof of identity, but it is still enough to
        // *contradict* one: this is the copilot-money shape (its own id lives only
        // in a trash path), which must still revoke a strong match for a
        // different app. Veto reasons over both buckets.
        let cask = Cask(
            token: "finance",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Shared.app")],
            cleanupBundleIdentifiers: ["com.finance.production"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Shared.app",
            bundleIdentifier: "com.otherapp.production"
        )

        #expect(
            resolver.eligibility(for: app)
                == .ineligible(reason: .strongMatchVetoed(caskToken: "finance"))
        )
    }

    // MARK: - Domain-aware veto: renames of the same app are not contradictions

    @Test
    func aSameOrganisationRenamedIdDoesNotVeto() {
        // The cask's only declared id is this same vendor's *old* id (a cleanup
        // path left over from a rename). It shares the app's organisational domain
        // (com.acme), so it is not a foreign contradiction: no veto. With
        // auto_updates == false the version check backstops it, so it is eligible.
        let cask = Cask(
            token: "widget",
            autoUpdates: false,
            artifacts: [CaskArtifact(kind: .app, target: "Widget.app")],
            cleanupBundleIdentifiers: ["com.acme.oldwidget"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Widget.app",
            bundleIdentifier: "com.acme.widget"
        )

        #expect(resolver.eligibility(for: app) == .eligible(caskToken: "widget"))
    }

    @Test
    func aForeignOrganisationIdStillVetoes() {
        // Same shape, but the declared id belongs to a *different* organisation and
        // does not name the app. This is the real threat (the Copilot shape), so
        // the strong match is revoked even though the cask does not auto-update.
        let cask = Cask(
            token: "widget",
            autoUpdates: false,
            artifacts: [CaskArtifact(kind: .app, target: "Widget.app")],
            cleanupBundleIdentifiers: ["com.evil.thing"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Widget.app",
            bundleIdentifier: "com.acme.widget"
        )

        #expect(
            resolver.eligibility(for: app)
                == .ineligible(reason: .strongMatchVetoed(caskToken: "widget"))
        )
    }

    @Test
    func aCrossOrganisationRenameIsRecognisedByNameAndNotVetoed() {
        // The MonitorControl shape: the app moved organisations (app.widget.*),
        // and the cask's cleanup id is the pre-rename identity under the *old*
        // organisation (me.oldvendor.*) whose final label still names the app.
        // That name match marks a rename, so the veto does not fire — but because
        // the cask auto-updates and the id is not corroborated, the fail-closed
        // gate withholds it as unconfirmed rather than vetoed.
        let cask = Cask(
            token: "widget",
            autoUpdates: true,
            artifacts: [CaskArtifact(kind: .app, target: "Widget.app")],
            cleanupBundleIdentifiers: ["me.oldvendor.Widget"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Widget.app",
            bundleIdentifier: "app.widget.Widget"
        )

        #expect(
            resolver.eligibility(for: app)
                == .ineligible(reason: .identityNotConfirmed(caskToken: "widget"))
        )
    }

    @Test
    func raspberryPiImagerIsAdoptableDespiteRenamedBundleId() throws {
        // The fixture proof of the same rule against real cask data: the installed
        // com.raspberrypi.rpi-imager against a cask that zaps only the pre-rename
        // com.raspberrypi.imagingutility. Same domain, non-auto-updating -> the
        // domain-aware veto lets it through as its own cask.
        let apps = try Fixture.installedApps()
        let resolver = try resolver()
        let app = try #require(Fixture.app(named: "Raspberry Pi Imager.app", in: apps))

        #expect(resolver.eligibility(for: app) == .eligible(caskToken: "raspberry-pi-imager"))
    }

    // MARK: - Already-managed gate

    @Test
    func strongMatchAlreadyManagedIsReportedAsSuch() throws {
        let apps = try Fixture.installedApps()
        let resolver = try resolver(managed: ["1password"])
        let app = try #require(Fixture.app(named: "1Password.app", in: apps))

        #expect(
            resolver.eligibility(for: app)
                == .ineligible(reason: .alreadyHomebrewManaged(caskToken: "1password"))
        )
    }

    // MARK: - Outcome prediction mirrors the verified adopt semantics

    @Test
    func autoUpdatingCaskSucceedsUnconditionally() throws {
        let index = CaskIndex(casks: try Fixture.casks())
        let resolver = MatchResolver(index: index)
        let apps = try Fixture.installedApps()
        let app = try #require(Fixture.app(named: "1Password.app", in: apps))
        let cask = try #require(index.cask(for: "1password"))

        #expect(resolver.predictOutcome(for: app, cask: cask) == .succeedsUnconditionally)
    }

    @Test
    func nonAutoUpdatingCaskWithDifferingVersionAbortsWithCaskError() {
        let cask = Cask(
            token: "example",
            version: "2.0.0",
            autoUpdates: false,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")],
            primaryBundleIdentifiers: ["com.example.app"]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: "com.example.app",
            shortVersion: "1.0.0",
            bundleVersion: "1.0.0"
        )

        #expect(resolver.predictOutcome(for: app, cask: cask) == .abortsWithCaskError)
    }

    @Test
    func nonAutoUpdatingCaskWithMatchingVersionSucceeds() {
        let cask = Cask(
            token: "example",
            version: "1.0.0",
            autoUpdates: false,
            artifacts: [CaskArtifact(kind: .app, target: "Example.app")]
        )
        let resolver = MatchResolver(index: CaskIndex(casks: [cask]))
        let app = InstalledApp(
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: "com.example.app",
            shortVersion: "9.9.9",
            bundleVersion: "1.0.0"
        )

        #expect(resolver.predictOutcome(for: app, cask: cask) == .succeeds)
    }
}
