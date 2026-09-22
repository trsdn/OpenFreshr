import Foundation
import Testing

@testable import OpenFreshrCore

@Suite("SoftwareUpdateListParser")
struct SoftwareUpdateListParserTests {

    private let real = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: Safari27.0TahoeAuto-27.0
        \tTitle: Safari, Version: 27.0, Size: 249465KiB, Recommended: YES, 
        * Label: Command Line Tools for Xcode 27.0-27.0
        \tTitle: Command Line Tools for Xcode 27.0, Version: 27.0, Size: 519460KiB, Recommended: YES, 
        * Label: macOS Tahoe  26.7-25G229
        \tTitle: macOS Tahoe  26.7, Version: 26.7, Size: 2960352KiB, Recommended: YES, Action: restart, 
        """

    @Test("Parses a real capture into three items, one requiring a restart")
    func parsesRealCapture() {
        let items = SoftwareUpdateListParser.parse(real)
        #expect(items.map(\.title) == ["Safari", "Command Line Tools for Xcode 27.0", "macOS Tahoe  26.7"])
        #expect(items.map(\.version) == ["27.0", "27.0", "26.7"])
        #expect(items.map(\.recommended) == [true, true, true])
        #expect(items.map(\.requiresRestart) == [false, false, true])
        #expect(items[2].label == "macOS Tahoe  26.7-25G229")
    }

    @Test("An error banner ahead of a real listing does not stop or corrupt parsing")
    func errorBannerIsIgnored() {
        let withBanner = """
            Software Update Tool
            Scan finished with error: Error Domain=SUMacControllerError Code=7507 "Access request was denied"
            Software Update found the following new or updated software:
            * Label: Safari27.0TahoeAuto-27.0
            \tTitle: Safari, Version: 27.0, Size: 249465KiB, Recommended: YES, 
            """
        #expect(SoftwareUpdateListParser.parse(withBanner).map(\.title) == ["Safari"])
    }

    @Test("No updates available parses to no items")
    func noUpdates() {
        let none = """
            Software Update Tool

            Finding available software
            No new software available.
            """
        #expect(SoftwareUpdateListParser.parse(none).isEmpty)
    }

    @Test("A Title line with no preceding Label line produces nothing")
    func titleWithoutLabel() {
        let orphan = "\tTitle: Safari, Version: 27.0, Recommended: YES, "
        #expect(SoftwareUpdateListParser.parse(orphan).isEmpty)
    }

    @Test("A blank Recommended or missing Action reads as not recommended, no restart")
    func defaults() {
        let minimal = """
            * Label: Something-1.0
            \tTitle: Something, Version: 1.0, 
            """
        let items = SoftwareUpdateListParser.parse(minimal)
        #expect(items.count == 1)
        #expect(!items[0].recommended)
        #expect(!items[0].requiresRestart)
    }
}
