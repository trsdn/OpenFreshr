import Foundation
import Testing

@testable import OpenFreshrCore

/// Coverage for the popularity table parser. It is fed an **untrusted** network
/// document, so the contract is: parse the comma-grouped counts Homebrew emits,
/// and degrade to an empty table on anything malformed rather than throwing.
struct CaskInstallAnalyticsTests {

    @Test
    func parsesCommaGroupedCounts() {
        let data = Data(
            #"""
            {"category":"cask-install","total_items":2,
             "items":[
                {"number":1,"cask":"google-chrome","count":"6,190,417"},
                {"number":2,"cask":"firefox","count":"1,000"}
             ]}
            """#.utf8)

        let analytics = CaskInstallAnalytics.parse(fromAPIData: data)

        #expect(analytics.count == 2)
        #expect(analytics.installs(for: "google-chrome") == 6_190_417)
        #expect(analytics.installs(for: "firefox") == 1_000)
        #expect(analytics.installs(for: "absent") == nil)
    }

    @Test
    func acceptsBareNumericCounts() {
        let data = Data(#"{"items":[{"cask":"iterm2","count":42}]}"#.utf8)
        let analytics = CaskInstallAnalytics.parse(fromAPIData: data)
        #expect(analytics.installs(for: "iterm2") == 42)
    }

    @Test
    func skipsEntriesMissingTokenOrCount() {
        let data = Data(
            #"""
            {"items":[
                {"cask":"ok","count":"5"},
                {"count":"9"},
                {"cask":"no-count"},
                {"cask":"bad-count","count":"n/a"}
            ]}
            """#.utf8)

        let analytics = CaskInstallAnalytics.parse(fromAPIData: data)

        #expect(analytics.installs(for: "ok") == 5)
        #expect(analytics.count == 1)
    }

    @Test
    func malformedDocumentYieldsEmptyTable() {
        #expect(CaskInstallAnalytics.parse(fromAPIData: Data("not json".utf8)).count == 0)
        #expect(CaskInstallAnalytics.parse(fromAPIData: Data("[]".utf8)).count == 0)
        #expect(CaskInstallAnalytics.parse(fromAPIData: Data(#"{"items":"nope"}"#.utf8)).count == 0)
    }
}
