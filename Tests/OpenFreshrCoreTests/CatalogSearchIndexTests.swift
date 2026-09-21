import Foundation
import Testing

@testable import OpenFreshrCore

/// The prepared catalog search index (Phase 5): finds casks by token, name and
/// description, ranks by popularity then name, marks already-installed casks and
/// flags installer-only casks — all off a `Sendable` value built once and queried
/// synchronously, fast enough for the full catalog.
struct CatalogSearchIndexTests {

    private func cask(
        _ token: String,
        names: [String] = [],
        desc: String? = nil,
        artifacts: [CaskArtifact] = [CaskArtifact(kind: .app, target: "App.app")],
        oldTokens: [String] = []
    ) -> Cask {
        Cask(token: token, names: names, oldTokens: oldTokens, desc: desc, artifacts: artifacts)
    }

    private func catalog(_ casks: [Cask]) -> CaskCatalog {
        CaskCatalog(casks: casks, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - search across token, name and description

    @Test
    func findsByToken() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("visual-studio-code", names: ["Visual Studio Code"]),
                cask("firefox", names: ["Firefox"]),
            ]))
        let hits = index.search("studio").map(\.cask.token)
        #expect(hits == ["visual-studio-code"])
    }

    @Test
    func findsByName() {
        // The token gives no hint; only the declared name carries the term.
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("iterm2", names: ["iTerm"]),
                cask("firefox", names: ["Firefox"]),
            ]))
        let hits = index.search("iterm").map(\.cask.token)
        #expect(hits == ["iterm2"])
    }

    @Test
    func findsByDescription() {
        // Neither token nor name mention "conferencing"; the description does.
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("zm", names: ["Zm"], desc: "Video conferencing and meetings"),
                cask("firefox", names: ["Firefox"], desc: "Web browser"),
            ]))
        let hits = index.search("conferencing").map(\.cask.token)
        #expect(hits == ["zm"])
    }

    @Test
    func andSemanticsNarrowsAcrossTerms() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("visual-studio-code", names: ["Visual Studio Code"]),
                cask("visualboyadvance-m", names: ["VisualBoyAdvance-M"]),
            ]))
        // "visual" alone matches both; adding "studio" must narrow to just one.
        #expect(
            Set(index.search("visual").map(\.cask.token))
                == ["visual-studio-code", "visualboyadvance-m"])
        #expect(index.search("visual studio").map(\.cask.token) == ["visual-studio-code"])
    }

    // MARK: - ranking

    @Test
    func ranksByPopularityDescendingThenNameAscending() {
        let analytics = CaskInstallAnalytics(installCountsByToken: [
            "beta": 500,
            "alpha": 500,
            "gamma": 9000,
        ])
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("alpha", names: ["Alpha"]),
                cask("beta", names: ["Beta"]),
                cask("gamma", names: ["Gamma"]),
            ]),
            analytics: analytics
        )
        // gamma (9000) first; then the 500-tie broken alphabetically: Alpha, Beta.
        #expect(index.allRanked().map(\.cask.token) == ["gamma", "alpha", "beta"])
        #expect(index.allRanked().map(\.installCount) == [9000, 500, 500])
    }

    @Test
    func missingAnalyticsFallsBackToStableAlphabeticalOrder() {
        // No analytics at all — search and ranking must still work, alphabetically.
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("charlie", names: ["Charlie"]),
                cask("alpha", names: ["Alpha"]),
                cask("bravo", names: ["Bravo"]),
            ]))
        #expect(index.allRanked().map(\.cask.token) == ["alpha", "bravo", "charlie"])
        #expect(index.allRanked().allSatisfy { $0.installCount == nil })
    }

    @Test
    func casksWithoutPopularitySortAfterCaskWithIt() {
        let analytics = CaskInstallAnalytics(installCountsByToken: ["known": 1])
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("unknown-a", names: ["Unknown A"]),
                cask("known", names: ["Known"]),
            ]),
            analytics: analytics
        )
        #expect(index.allRanked().map(\.cask.token) == ["known", "unknown-a"])
    }

    // MARK: - already-installed marking

    @Test
    func marksInstalledByBundleNameCaseInsensitively() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask(
                    "firefox", names: ["Firefox"],
                    artifacts: [CaskArtifact(kind: .app, target: "Firefox.app")]),
                cask(
                    "iterm2", names: ["iTerm"],
                    artifacts: [CaskArtifact(kind: .app, target: "iTerm.app")]),
            ]),
            installedBundleNames: ["firefox.app"]  // different case on purpose
        )
        let firefox = index.search("firefox").first
        #expect(firefox?.isInstalled == true)
        #expect(firefox?.installedBundleName == "Firefox.app")

        let iterm = index.search("iterm").first
        #expect(iterm?.isInstalled == false)
        #expect(iterm?.installedBundleName == nil)
    }

    @Test
    func marksInstalledByRecognizedTokenEvenWithoutBundleMatch() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask(
                    "someapp", names: ["Some App"],
                    artifacts: [CaskArtifact(kind: .app, target: "SomeApp.app")])
            ]),
            installedBundleNames: [],  // nothing matches by filename
            recognizedTokens: ["someapp"]  // …but the token is recognized
        )
        #expect(index.search("some").first?.isInstalled == true)
    }

    // MARK: - installer-only flagging

    @Test
    func flagsInstallerOnlyCask() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask(
                    "appcask", names: ["App Cask"],
                    artifacts: [CaskArtifact(kind: .app, target: "App.app")]),
                cask(
                    "pkgcask", names: ["Pkg Cask"],
                    artifacts: [CaskArtifact(kind: .pkg)]),
            ]))
        #expect(index.search("app cask").first?.isInstallerOnly == false)
        let pkg = index.search("pkg cask").first
        #expect(pkg?.isInstallerOnly == true)
    }

    // MARK: - browse mode

    @Test
    func emptyQueryReturnsWholeCatalogRanked() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("alpha", names: ["Alpha"]),
                cask("bravo", names: ["Bravo"]),
            ]))
        #expect(index.count == 2)
        #expect(index.search("").count == 2)
        #expect(index.search("   ").count == 2)
    }

    @Test
    func limitCapsResults() {
        let index = CatalogSearchIndex(
            catalog: catalog([
                cask("alpha", names: ["Alpha"]),
                cask("bravo", names: ["Bravo"]),
                cask("charlie", names: ["Charlie"]),
            ]))
        #expect(index.allRanked(limit: 2).count == 2)
        #expect(index.search("a", limit: 1).count == 1)
    }

    // MARK: - scale & latency

    @Test
    func searchOverFullCatalogStaysFast() {
        // Build a catalog the size of the live one (~7716 casks) with realistic
        // descriptions, then confirm both the build and a search stay quick.
        var casks: [Cask] = []
        casks.reserveCapacity(8000)
        for i in 0..<8000 {
            casks.append(
                cask(
                    "tool-\(i)",
                    names: ["Tool \(i)"],
                    desc: "A utility number \(i) for doing useful things on macOS"
                )
            )
        }
        // Give the last one a needle the description search must find.
        casks.append(cask("needle-app", names: ["Needle"], desc: "A very distinctive kryptonite finder"))

        let clock = ContinuousClock()
        let buildStart = clock.now
        let index = CatalogSearchIndex(
            catalog: catalog(casks),
            analytics: CaskInstallAnalytics(installCountsByToken: ["needle-app": 12345])
        )
        let buildDuration = clock.now - buildStart
        #expect(index.count == 8001)

        // Measure the cost of a description search across the whole catalog.
        let searchStart = clock.now
        var found: [CatalogSearchResult] = []
        let iterations = 20
        for _ in 0..<iterations {
            found = index.search("kryptonite")
        }
        let searchDuration = clock.now - searchStart
        let perSearch = searchDuration / iterations

        #expect(found.map(\.cask.token) == ["needle-app"])
        // Generous bounds: a prepared substring scan over ~8000 entries is
        // sub-millisecond in practice; assert well under a second to stay robust
        // on loaded CI while still catching an accidental O(n^2) regression.
        #expect(buildDuration < .seconds(2))
        #expect(perSearch < .milliseconds(250))

        print("[catalog-search] entries=\(index.count) build=\(buildDuration) perSearch≈\(perSearch)")
    }

    @Test
    func indexesRealFixtureCatalogAndFindsAKnownToken() throws {
        let casks = try Fixture.casks()
        let index = CatalogSearchIndex(catalog: catalog(casks))
        #expect(index.count == casks.count)
        // Every fixture token must be findable by its own token.
        for cask in casks {
            let hits = index.search(cask.token).map(\.cask.token)
            #expect(hits.contains(cask.token), "expected to find \(cask.token) by token")
        }
    }
}
