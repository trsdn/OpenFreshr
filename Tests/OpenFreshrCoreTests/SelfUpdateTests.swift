import Foundation
import Testing
@testable import OpenFreshrCore

/// OpenFreshr's *self*-update check. It reuses the appcast reader and the
/// fail-closed comparator, so these tests focus on the one new decision:
/// mapping (current version, newest-in-feed) to a ``SelfUpdateStatus`` that is
/// never a false positive.
struct SelfUpdateCheckerTests {

    private let feed = "https://trsdn.github.io/OpenFreshr/appcast.xml"

    private func appcast(items: String) -> Data {
        Data("""
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
        \(items)
          </channel>
        </rss>
        """.utf8)
    }

    private func fetcher(serving body: Data) -> FakeHTTPFetcher {
        let fetcher = FakeHTTPFetcher()
        fetcher.setData(body, for: feed)
        return fetcher
    }

    @Test
    func reportsUpdateWhenTheFeedIsNewer() async {
        let fetcher = fetcher(serving: appcast(
            items: "<item><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString></item>"
        ))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .updateAvailable(version: "1.1.0"))
        #expect(status.hasUpdate)
        #expect(status.latestVersion == "1.1.0")
    }

    @Test
    func reportsUpToDateWhenVersionsMatch() async {
        let fetcher = fetcher(serving: appcast(
            items: "<item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString></item>"
        ))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .upToDate)
        #expect(!status.hasUpdate)
    }

    @Test
    func reportsUpToDateWhenTheRunningBuildIsAhead() async {
        // A locally built pre-release must never be told to "downgrade".
        let fetcher = fetcher(serving: appcast(
            items: "<item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString></item>"
        ))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.1.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .upToDate)
    }

    @Test
    func picksTheNewestAcrossSeveralItems() async {
        let fetcher = fetcher(serving: appcast(items: """
        <item><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString></item>
        <item><sparkle:shortVersionString>1.3.0</sparkle:shortVersionString></item>
        <item><sparkle:shortVersionString>1.2.0</sparkle:shortVersionString></item>
        """))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .updateAvailable(version: "1.3.0"))
    }

    @Test
    func unreachableFeedIsUnknownNotAnUpdate() async {
        let fetcher = FakeHTTPFetcher()
        fetcher.setFailure("offline", for: feed)
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .unknown)
        #expect(!status.hasUpdate)
        #expect(status.latestVersion == nil)
    }

    @Test
    func unparsableFeedIsUnknownNotAnUpdate() async {
        let fetcher = fetcher(serving: Data("<not an appcast".utf8))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .unknown)
    }

    @Test
    func incomparableVersionsAreUnknownNotAnUpdate() async {
        // A marketing tie separated only by a pre-release qualifier cannot be
        // ordered, so it must not be surfaced as an update.
        let fetcher = fetcher(serving: appcast(
            items: "<item><sparkle:shortVersionString>1.0.0-beta</sparkle:shortVersionString></item>"
        ))
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: feed, using: fetcher
        )
        #expect(status.availability == .unknown)
    }

    @Test
    func nonHttpFeedIsUnknownWithoutTouchingTheNetwork() async {
        let fetcher = FakeHTTPFetcher()
        let status = await SelfUpdateChecker.check(
            currentVersion: "1.0.0", feedURL: "file:///etc/passwd", using: fetcher
        )
        #expect(status.availability == .unknown)
        #expect(fetcher.requestedURLs.isEmpty)
    }
}
