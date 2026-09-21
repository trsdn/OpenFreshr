import Foundation
import Testing

@testable import OpenFreshrCore

/// Unit coverage for the ingestion path that finally *populates* the two bundle
/// identifier buckets from the real Homebrew cask API shape — and, crucially,
/// keeps them **apart**: strong identity fields land in
/// ``Cask/primaryBundleIdentifiers`` while ids recovered from `trash`/`delete`
/// *paths* land in ``Cask/cleanupBundleIdentifiers``.
///
/// These are the exact recovery cases the reviewers called out: identity that
/// only ever appears embedded in `zap`/`uninstall` *paths*, two-component ids
/// like `md.obsidian`, reverse-DNS ids that merely end in `.app`, a leading
/// Apple Team ID, and the `com.apple.*`/`group.*` namespaces that must never be
/// mistaken for the installed app's own identity.
struct CaskCatalogIngestionTests {

    /// Build the raw bytes of a one-cask `cask.json` document from a dictionary.
    private func apiData(_ cask: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [cask])
    }

    private func ingestOne(_ cask: [String: Any]) throws -> Cask {
        let casks = try CaskCatalogIngestion.casks(fromAPIData: apiData(cask))
        return try #require(casks.first)
    }

    // MARK: - End-to-end recovery from the real API shape

    @Test
    func copilotMoneyIdentityIsRecoveredFromAContainerPath() throws {
        // The verified real trap: identity lives only in a zap trash *path*, so it
        // must land in the *cleanup* bucket — never in the strong identity bucket.
        let cask = try ingestOne([
            "token": "copilot-money",
            "auto_updates": true,
            "version": "1.2.3",
            "artifacts": [
                ["app": ["Copilot.app"], "target": "Copilot.app"],
                ["zap": [["trash": "~/Library/Containers/com.copilot.production"]]],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers == [])
        #expect(cask.cleanupBundleIdentifiers == ["com.copilot.production"])
        #expect(cask.autoUpdates == true)
        #expect(cask.version == "1.2.3")
        #expect(cask.movedArtifactTargets == ["Copilot.app"])
        // The decisive property: com.microsoft.copilot-mac contradicts this, so
        // the veto — which reasons over both buckets — has real data to fire on.
        #expect(!cask.cleanupBundleIdentifiers.contains("com.microsoft.copilot-mac"))
    }

    @Test
    func twoComponentIdentifierSurvivesFromAPreferencesPath() throws {
        // md.obsidian has only two components; a three-component regex would drop
        // it. The `.plist` suffix must be stripped first. Path id → cleanup.
        let cask = try ingestOne([
            "token": "obsidian",
            "artifacts": [
                ["app": ["Obsidian.app"], "target": "Obsidian.app"],
                ["zap": [["trash": "~/Library/Preferences/md.obsidian.plist"]]],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers == [])
        #expect(cask.cleanupBundleIdentifiers == ["md.obsidian"])
    }

    @Test
    func identifierIsRecoveredFromAnApplicationSupportPath() throws {
        let cask = try ingestOne([
            "token": "vlc",
            "artifacts": [
                ["app": ["VLC.app"], "target": "VLC.app"],
                ["zap": [["trash": "~/Library/Application Support/org.videolan.vlc"]]],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers == [])
        #expect(cask.cleanupBundleIdentifiers == ["org.videolan.vlc"])
    }

    @Test
    func identityFieldsOfUninstallStanzasAreHarvested() throws {
        // elgato-camera-hub names a foreign helper via `quit`; a strong field
        // always lands in the primary (identity) bucket.
        let cask = try ingestOne([
            "token": "elgato-camera-hub",
            "artifacts": [
                ["app": ["Camera Hub.app"], "target": "Camera Hub.app"],
                ["uninstall": [["quit": "com.displaylink.DisplayLinkUserAgent"]]],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers.contains("com.displaylink.DisplayLinkUserAgent"))
        #expect(cask.cleanupBundleIdentifiers.isEmpty)
    }

    @Test
    func signalPairsContributeTheIdentifierButNotTheSignalName() throws {
        // `signal` entries are [SIGNAL, id] pairs; only the id is identity.
        let cask = try ingestOne([
            "token": "example",
            "artifacts": [
                ["app": ["Example.app"], "target": "Example.app"],
                ["uninstall": [["signal": ["TERM", "com.example.helper"]]]],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers == ["com.example.helper"])
        #expect(cask.cleanupBundleIdentifiers.isEmpty)
    }

    @Test
    func multipleStanzasAreUnionedAndSorted() throws {
        let cask = try ingestOne([
            "token": "example",
            "artifacts": [
                ["app": ["Example.app"], "target": "Example.app"],
                [
                    "zap": [
                        [
                            "trash": [
                                "~/Library/Containers/com.example.app",
                                "~/Library/Saved Application State/com.example.app.savedState",
                                "~/Library/Preferences/com.example.helper.plist",
                            ]
                        ]
                    ]
                ],
            ],
        ])

        // All three come from *paths*, so they union into cleanup, not primary.
        #expect(cask.primaryBundleIdentifiers == [])
        #expect(cask.cleanupBundleIdentifiers == ["com.example.app", "com.example.helper"])
    }

    @Test
    func strongFieldsAndPathIdsAreSplitAcrossTheTwoBuckets() throws {
        // A cask that declares *both* a strong identity (`quit`) and cleanup
        // paths must file each id under the right bucket. A path id that also
        // appears as a strong field stays only in primary (no duplication).
        let cask = try ingestOne([
            "token": "example",
            "artifacts": [
                ["app": ["Example.app"], "target": "Example.app"],
                ["uninstall": [["quit": "com.example.app"]]],
                [
                    "zap": [
                        [
                            "trash": [
                                "~/Library/Containers/com.example.app",
                                "~/Library/Containers/com.foreign.debris",
                            ]
                        ]
                    ]
                ],
            ],
        ])

        #expect(cask.primaryBundleIdentifiers == ["com.example.app"])
        #expect(cask.cleanupBundleIdentifiers == ["com.foreign.debris"])
    }

    // MARK: - Canonicalisation edge cases (the guardrails)

    @Test
    func reverseDNSIdentifierEndingInAppIsKept() {
        // com.cmuxterm.app is a real reverse-DNS id, not a bundle folder name.
        #expect(CaskCatalogIngestion.canonicalBundleID("com.cmuxterm.app") == "com.cmuxterm.app")
    }

    @Test
    func bundleFolderNameIsRejected() {
        // OneDrive.app is a file name, not an identity (<= 2 components + folder
        // suffix).
        #expect(CaskCatalogIngestion.canonicalBundleID("OneDrive.app") == nil)
        #expect(CaskCatalogIngestion.canonicalBundleID("Copilot.app") == nil)
    }

    @Test
    func leadingAppleTeamIdentifierIsStripped() {
        #expect(CaskCatalogIngestion.canonicalBundleID("UBF8T346G9.com.foo.bar") == "com.foo.bar")
    }

    @Test
    func appleAndGroupNamespacesAreNotIdentity() {
        #expect(CaskCatalogIngestion.canonicalBundleID("com.apple.Safari") == nil)
        #expect(CaskCatalogIngestion.canonicalBundleID("group.com.example.shared") == nil)
    }

    @Test
    func singleComponentTokensAreNotIdentifiers() {
        // A bare signal name or word is never a bundle id.
        #expect(CaskCatalogIngestion.canonicalBundleID("TERM") == nil)
        #expect(CaskCatalogIngestion.canonicalBundleID("") == nil)
    }

    @Test
    func applePathsInCleanupAreIgnoredWhileTheOwnIdentityIsKept() throws {
        let cask = try ingestOne([
            "token": "example",
            "artifacts": [
                ["app": ["Example.app"], "target": "Example.app"],
                [
                    "zap": [
                        [
                            "trash": [
                                "~/Library/Preferences/com.apple.LaunchServices.plist",
                                "~/Library/Preferences/com.example.app.plist",
                            ]
                        ]
                    ]
                ],
            ],
        ])

        // Both come from paths: the Apple id is dropped, the own id → cleanup.
        #expect(cask.primaryBundleIdentifiers == [])
        #expect(cask.cleanupBundleIdentifiers == ["com.example.app"])
    }
}
