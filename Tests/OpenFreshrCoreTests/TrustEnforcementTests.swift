import Foundation
import Testing
@testable import OpenFreshrCore

/// The trust gate wired into the coordinators, proving the contract that matters
/// most: a team-ID change (or an unsigned/invalid bundle) is refused **before**
/// any backend runs — in the single, batch and major-upgrade paths — and, after
/// an explicit opt-in, the action runs and the change is logged. Nothing here
/// touches real `codesign`, real `brew`, or `/Applications`.
struct TrustEnforcementTests {

    // MARK: - Builders

    /// A Homebrew-only update coordinator with an injected trust gate. Returns the
    /// coordinator plus the `brew` runner so a test can assert the backend was (or
    /// was not) invoked.
    private func makeCoordinator(
        apps: [[InstalledApp]],
        casks: [Cask],
        brewList: String,
        trustGate: TrustGate
    ) -> (UpdateCoordinator, RecordingProcessRunner) {
        var fs = FakeFileSystem()
        fs.addExistingPath("/opt/homebrew/bin/brew")

        let brewRunner = RecordingProcessRunner { _, args in
            if args == ["list", "--cask", "-1"] {
                return ProcessResult(exitCode: 0, standardOutput: brewList, standardError: "")
            }
            if args == ["list", "--cask", "--versions"] {
                return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
            }
            return ProcessResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }
        let idle = RecordingProcessRunner()

        let coordinator = UpdateCoordinator(
            scanner: ScriptedScanner(snapshots: apps),
            homebrew: HomebrewBackend(processRunner: brewRunner, fileSystem: fs),
            macAppStore: MacAppStoreBackend(processRunner: idle, fileSystem: fs),
            microsoftAutoUpdate: MicrosoftAutoUpdateBackend(processRunner: idle, fileSystem: fs),
            catalog: CaskCatalog(casks: casks, fetchedAt: Date()),
            httpFetcher: FakeHTTPFetcher(),
            scanDirectories: ["/Applications"],
            trustGate: trustGate
        )
        return (coordinator, brewRunner)
    }

    /// A drivable Homebrew item whose app carries a real bundle identifier (so the
    /// trust gate has an identity to key on) — unlike the identity-less helper in
    /// `UpdateCoordinatorTests`.
    private func homebrewItem(
        bundlePath: String, bundleIdentifier: String, token: String,
        target: String, isMajor: Bool = false
    ) -> UpdateItem {
        let plan = HomebrewBackend.commandPlan(for: .upgrade, token: token).map {
            ResolvedCommand(executablePath: "/opt/homebrew/bin/brew", arguments: $0)
        }
        return UpdateItem(
            app: InstalledApp(bundlePath: bundlePath, bundleIdentifier: bundleIdentifier, shortVersion: nil),
            sourceKind: .homebrew(token: token),
            backend: .homebrew,
            command: plan[0],
            targetVersion: target,
            isMajor: isMajor,
            homebrewStrategy: .upgrade,
            commandPlan: plan
        )
    }

    private let figmaPath = "/Applications/Figma.app"
    private let figmaID = "com.figma.Desktop"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A store carrying an old Figma baseline plus a gate whose inspector reports a
    /// *new* team — i.e. a pending, unacknowledged team-ID change.
    private func teamChangeGate() -> (TrustGate, InMemoryTrustStore) {
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified(figmaPath, team: "NEWTEAM222"), store: store)
        return (gate, store)
    }

    // MARK: - Single path

    @Test
    func teamChangeBlocksSingleUpdateBeforeBackendRuns() {
        let (gate, store) = teamChangeGate()
        let (coordinator, brew) = makeCoordinator(
            apps: [[InstalledApp(bundlePath: figmaPath, bundleIdentifier: figmaID, shortVersion: "1.2.4")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            brewList: "figma\n",
            trustGate: gate
        )
        let item = homebrewItem(bundlePath: figmaPath, bundleIdentifier: figmaID, token: "figma", target: "1.2.4")

        let outcome = coordinator.perform(item)

        guard case let .blockedByTrust(_, block) = outcome,
              case let .teamIdentifierChanged(change) = block else {
            Issue.record("expected .blockedByTrust(.teamIdentifierChanged), got \(outcome)")
            return
        }
        #expect(change.previousTeamIdentifier == "OLDTEAM111")
        #expect(change.newTeamIdentifier == "NEWTEAM222")
        #expect(outcome.didUpdate == false)
        #expect(outcome.isRetryable == false)
        // The decisive proof: the backend was never consulted at all.
        #expect(brew.invocations.isEmpty)
        // And the baseline did not silently advance.
        #expect(store.record(for: "com.figma.desktop")?.teamIdentifier == "OLDTEAM111")
    }

    @Test
    func optInLetsTheSingleUpdateRunAndLogsTheChange() {
        let (gate, store) = teamChangeGate()
        let (coordinator, brew) = makeCoordinator(
            apps: [[InstalledApp(bundlePath: figmaPath, bundleIdentifier: figmaID, shortVersion: "1.2.4")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            brewList: "figma\n",
            trustGate: gate
        )
        let item = homebrewItem(bundlePath: figmaPath, bundleIdentifier: figmaID, token: "figma", target: "1.2.4")

        let outcome = coordinator.perform(item, acknowledgingTeamChange: true)

        #expect(outcome.didUpdate)                                   // confirmed by rescan
        #expect(brew.invocations.contains { $0.arguments.first == "upgrade" })
        let record = store.record(for: "com.figma.desktop")
        #expect(record?.teamIdentifier == "NEWTEAM222")
        #expect(record?.origin == .userConfirmedChange)
        #expect(record?.confirmedChanges.count == 1)
    }

    // MARK: - Batch path

    @Test
    func teamChangeBlocksInsideABatchWhileOthersProceed() async throws {
        // Figma has a pending team change; Slack is a clean first-use. The batch
        // must block Figma before its backend runs, yet still update Slack.
        let slackPath = "/Applications/Slack.app"
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.figma.desktop", teamIdentifier: "OLDTEAM111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let inspector = FakeCodeSignatureInspector(infos: [
            figmaPath: CodeSignatureInfo(teamIdentifier: "NEWTEAM222", verification: .verified, gatekeeper: .accepted),
            slackPath: CodeSignatureInfo(teamIdentifier: "SLACKTEAM0", verification: .verified, gatekeeper: .accepted),
        ])
        let gate = TrustGate(inspector: inspector, store: store)

        let (coordinator, brew) = makeCoordinator(
            apps: [[
                InstalledApp(bundlePath: figmaPath, bundleIdentifier: figmaID, shortVersion: "1.2.4"),
                InstalledApp(bundlePath: slackPath, bundleIdentifier: "com.tinyspeck.slackmacgap", shortVersion: "3.1"),
            ]],
            casks: [
                Cask(token: "figma", names: ["Figma"], version: "1.2.4"),
                Cask(token: "slack", names: ["Slack"], version: "3.1"),
            ],
            brewList: "figma\nslack\n",
            trustGate: gate
        )
        let figmaItem = homebrewItem(bundlePath: figmaPath, bundleIdentifier: figmaID, token: "figma", target: "1.2.4")
        let slackItem = homebrewItem(bundlePath: slackPath, bundleIdentifier: "com.tinyspeck.slackmacgap", token: "slack", target: "3.1")
        let release = try #require(UpdateRelease(items: [figmaItem, slackItem]))

        let result = await coordinator.perform(release)     // no acknowledgements

        // Figma blocked by trust …
        #expect(result.outcomes.contains { if case .blockedByTrust = $0 { return true }; return false })
        #expect(result.updatedItems.map(\.app.bundleName) == ["Slack.app"])
        // … and its `brew upgrade` never ran, while Slack's did.
        #expect(brew.invocations.contains { $0.arguments == ["upgrade", "--cask", "--greedy", "--", "slack"] })
        #expect(brew.invocations.contains { $0.arguments.contains("figma") } == false)
    }

    @Test
    func optInInsideABatchIsScopedToTheAcknowledgedApp() async throws {
        let (gate, _) = teamChangeGate()
        let (coordinator, brew) = makeCoordinator(
            apps: [[InstalledApp(bundlePath: figmaPath, bundleIdentifier: figmaID, shortVersion: "1.2.4")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            brewList: "figma\n",
            trustGate: gate
        )
        let figmaItem = homebrewItem(bundlePath: figmaPath, bundleIdentifier: figmaID, token: "figma", target: "1.2.4")
        let release = try #require(UpdateRelease(items: [figmaItem]))

        let result = await coordinator.perform(release, acknowledgingTeamChanges: [figmaPath])

        #expect(result.updatedItems.map(\.app.bundleName) == ["Figma.app"])
        #expect(brew.invocations.contains { $0.arguments.first == "upgrade" })
    }

    // MARK: - Major path

    @Test
    func teamChangeBlocksAMajorUpgradeBeforeBackendRuns() async throws {
        // A major release routes through the same `perform`, so the gate must
        // still fire first. Bigapp jumps 1.x → 2.0 (major) and its team changed.
        let bigPath = "/Applications/Bigapp.app"
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.example.bigapp", teamIdentifier: "OLDBIG1111",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified(bigPath, team: "NEWBIG2222"), store: store)

        let (coordinator, brew) = makeCoordinator(
            apps: [[InstalledApp(bundlePath: bigPath, bundleIdentifier: "com.example.Bigapp", shortVersion: "2.0.0")]],
            casks: [Cask(token: "bigapp", names: ["Bigapp"], version: "2.0.0")],
            brewList: "bigapp\n",
            trustGate: gate
        )
        let majorItem = homebrewItem(bundlePath: bigPath, bundleIdentifier: "com.example.Bigapp",
                                     token: "bigapp", target: "2.0.0", isMajor: true)
        let release = try #require(UpdateRelease(items: [majorItem]))
        #expect(release.isMajor)

        let result = await coordinator.perform(release)

        #expect(result.outcomes.contains { if case .blockedByTrust = $0 { return true }; return false })
        #expect(result.updatedItems.isEmpty)
        #expect(brew.invocations.isEmpty)
    }

    // MARK: - Unsigned / invalid hard block (single path)

    @Test
    func unsignedBundleHardBlocksTheSingleUpdate() {
        let gate = TrustGate(
            inspector: FakeCodeSignatureInspector(infos: [
                figmaPath: CodeSignatureInfo(teamIdentifier: nil, verification: .unsigned, gatekeeper: .rejected("x"))
            ]),
            store: InMemoryTrustStore())
        let (coordinator, brew) = makeCoordinator(
            apps: [[InstalledApp(bundlePath: figmaPath, bundleIdentifier: figmaID, shortVersion: "1.2.4")]],
            casks: [Cask(token: "figma", names: ["Figma"], version: "1.2.4")],
            brewList: "figma\n",
            trustGate: gate
        )
        let item = homebrewItem(bundlePath: figmaPath, bundleIdentifier: figmaID, token: "figma", target: "1.2.4")

        let outcome = coordinator.perform(item)

        #expect(outcome.trustBlock == .unsigned)
        #expect(brew.invocations.isEmpty)
    }

    // MARK: - Adoption gate (defense in depth)

    @Test
    func teamChangeBlocksAdoptionBeforeBackendRuns() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        // A stored baseline that differs from the inspected team → pending change.
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.1password.1password", teamIdentifier: "OLD1PW0000",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified(onePassword.bundlePath, team: "NEW1PW9999"), store: store)
        let backend = FakeBackend()

        let coordinator = AdoptionCoordinator(
            scanner: InventoryScanner(fileSystem: FakeFileSystem(apps: apps)),
            backend: backend,
            catalog: CaskCatalog(casks: try Fixture.casks(), fetchedAt: Date()),
            scanDirectories: ["/Applications"],
            trustGate: gate
        )

        let result = coordinator.adopt(onePassword)

        guard case let .blockedByTrust(block) = result, case .teamIdentifierChanged = block else {
            Issue.record("expected .blockedByTrust(.teamIdentifierChanged), got \(result)")
            return
        }
        // The backend adopt was never called — the gate stopped it first.
        #expect(backend.adoptCalls.isEmpty)
    }

    @Test
    func optInLetsAdoptionProceed() throws {
        let apps = try Fixture.installedApps()
        let onePassword = try #require(Fixture.app(named: "1Password.app", in: apps))
        let store = InMemoryTrustStore(records: [
            TrustRecord(bundleIdentifier: "com.1password.1password", teamIdentifier: "OLD1PW0000",
                        firstObservedAt: epoch, updatedAt: epoch, origin: .firstUse)
        ])
        let gate = TrustGate(inspector: FakeCodeSignatureInspector.verified(onePassword.bundlePath, team: "NEW1PW9999"), store: store)
        let backend = FakeBackend(adoptResult: .succeeded(standardOutput: "ok"), adoptBecomesManaged: true)

        let coordinator = AdoptionCoordinator(
            scanner: InventoryScanner(fileSystem: FakeFileSystem(apps: apps)),
            backend: backend,
            catalog: CaskCatalog(casks: try Fixture.casks(), fetchedAt: Date()),
            scanDirectories: ["/Applications"],
            trustGate: gate
        )

        let result = coordinator.adopt(onePassword, acknowledgingTeamChange: true)

        guard case .adopted = result else {
            Issue.record("expected .adopted after opt-in, got \(result)")
            return
        }
        #expect(backend.adoptCalls.count == 1)
        #expect(store.record(for: "com.1password.1password")?.origin == .userConfirmedChange)
    }
}
