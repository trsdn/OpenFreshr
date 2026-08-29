import Foundation
import Testing
@testable import OpenFreshrCore

/// `mas outdated` line parsing. The tool is authoritative for the store, so the
/// parser's job is only to read its lines faithfully and skip anything that is
/// not an app row — noise must never become a phantom update.
struct MasOutdatedParserTests {

    @Test
    func parsesTheDocumentedTwoLineForm() {
        let output = """
        497799835 Xcode (14.0 -> 14.1)
        1295203466 Microsoft Remote Desktop (10.7.6 -> 10.8.0)
        """
        let entries = MasOutdatedParser.parse(output)
        #expect(entries.count == 2)
        #expect(entries[0] == MasOutdatedEntry(
            identifier: "497799835", name: "Xcode",
            installedVersion: "14.0", availableVersion: "14.1"
        ))
        #expect(entries[1].identifier == "1295203466")
        #expect(entries[1].name == "Microsoft Remote Desktop")
        #expect(entries[1].availableVersion == "10.8.0")
    }

    @Test
    func skipsBlankAndMalformedLines() {
        let output = """

        this is not an app row
        497799835 Xcode (14.0 -> 14.1)
        garbage 1.0 -> 2.0
        """
        let entries = MasOutdatedParser.parse(output)
        #expect(entries.count == 1)
        #expect(entries[0].identifier == "497799835")
    }

    @Test
    func emptyOutputYieldsNoEntries() {
        #expect(MasOutdatedParser.parse("").isEmpty)
        #expect(MasOutdatedParser.parse("\n\n").isEmpty)
    }
}

/// `msupdate --list` parsing. The layout drifts across releases, so parsing is
/// shape-tolerant but anchored on the bracketed MAU app code; a line without one
/// is not an app row, and a row without a dotted version keeps `nil` rather than
/// inventing one.
struct MsupdateListParserTests {

    @Test
    func parsesBracketedAppCodeAndVersion() {
        let output = """
        Word (MSWD2019) Version: 16.78 (23...)
        Excel (XCEL2019) Version: 16.78
        """
        let entries = MsupdateListParser.parse(output)
        #expect(entries.count == 2)
        #expect(entries[0].appID == "MSWD2019")
        #expect(entries[0].title == "Word")
        #expect(entries[0].availableVersion == "16.78")
        #expect(entries[1].appID == "XCEL2019")
    }

    @Test
    func acceptsSquareBracketsToo() {
        let entries = MsupdateListParser.parse("OneDrive [ONDR18] 24.086.0428")
        #expect(entries.count == 1)
        #expect(entries[0].appID == "ONDR18")
        #expect(entries[0].availableVersion == "24.086.0428")
    }

    @Test
    func rowWithoutAVersionKeepsNil() {
        // Anchored on the app code, so it is still an entry — but with no invented
        // version, which downgrades to *unbekannt* downstream.
        let entries = MsupdateListParser.parse("Word (MSWD2019) up to date")
        #expect(entries.count == 1)
        #expect(entries[0].appID == "MSWD2019")
        #expect(entries[0].availableVersion == nil)
    }

    @Test
    func linesWithoutAnAppCodeAreSkippedAndDuplicatesCollapse() {
        let output = """
        Updates available:
        Word (MSWD2019) 16.78
        Word (MSWD2019) 16.78
        """
        let entries = MsupdateListParser.parse(output)
        #expect(entries.count == 1)
        #expect(entries[0].appID == "MSWD2019")
    }
}

/// Sparkle appcast reading, including the ``HTTPFetching`` wiring. Every failure
/// path must resolve to `nil` so the resolver degrades to *unbekannt*.
struct SparkleAppcastTests {

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

    @Test
    func readsShortVersionFromChildElements() {
        let data = appcast(items: """
        <item><sparkle:shortVersionString>2.0</sparkle:shortVersionString><sparkle:version>2000</sparkle:version></item>
        """)
        #expect(SparkleAppcast.newestVersion(from: data) == "2.0")
    }

    @Test
    func readsVersionFromEnclosureAttributes() {
        let data = appcast(items: """
        <item><enclosure url="https://example.com/app.zip" sparkle:shortVersionString="3.1" sparkle:version="3100"/></item>
        """)
        #expect(SparkleAppcast.newestVersion(from: data) == "3.1")
    }

    @Test
    func picksTheNewestAcrossMultipleItems() {
        let data = appcast(items: """
        <item><sparkle:shortVersionString>1.0</sparkle:shortVersionString></item>
        <item><sparkle:shortVersionString>3.2</sparkle:shortVersionString></item>
        <item><sparkle:shortVersionString>2.5</sparkle:shortVersionString></item>
        """)
        #expect(SparkleAppcast.newestVersion(from: data) == "3.2")
    }

    @Test
    func fallsBackToBuildVersionWhenNoShortString() {
        let data = appcast(items: "<item><sparkle:version>4200</sparkle:version></item>")
        #expect(SparkleAppcast.newestVersion(from: data) == "4200")
    }

    @Test
    func malformedXmlYieldsNil() {
        #expect(SparkleAppcast.newestVersion(from: Data("<not xml".utf8)) == nil)
    }

    @Test
    func feedWithoutAnyVersionYieldsNil() {
        let data = appcast(items: "<item><title>Release</title></item>")
        #expect(SparkleAppcast.newestVersion(from: data) == nil)
    }

    @Test
    func fetchReturnsVersionForAReachableFeed() async {
        let fetcher = FakeHTTPFetcher()
        let feed = "https://example.com/appcast.xml"
        fetcher.setData(appcast(items: "<item><sparkle:shortVersionString>5.5</sparkle:shortVersionString></item>"), for: feed)
        let version = await SparkleAppcast.fetchNewestVersion(feedURL: feed, using: fetcher)
        #expect(version == "5.5")
        #expect(fetcher.requestedURLs == [feed])
    }

    @Test
    func fetchReturnsNilForAnUnreachableFeed() async {
        let fetcher = FakeHTTPFetcher()
        let feed = "https://example.com/appcast.xml"
        fetcher.setFailure("offline", for: feed)
        let version = await SparkleAppcast.fetchNewestVersion(feedURL: feed, using: fetcher)
        #expect(version == nil)
    }

    @Test
    func fetchRefusesNonHttpSchemesWithoutTouchingTheFetcher() async {
        let fetcher = FakeHTTPFetcher()
        let version = await SparkleAppcast.fetchNewestVersion(feedURL: "ftp://example.com/x", using: fetcher)
        #expect(version == nil)
        #expect(fetcher.requestedURLs.isEmpty)
    }
}
