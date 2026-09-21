import Foundation
import Testing

@testable import OpenFreshrCore

/// The single definition of "how many updates are available". These tests pin it
/// to exactly the predicate the window's "Updates" filter uses, so the menu-bar
/// badge and the window list can never disagree.
struct MenuBarStatusTests {

    /// Build a one-source report in a given state.
    private func report(
        _ path: String,
        state: UpdateState,
        isSelfUpdating: Bool = false
    ) -> AppUpdateReport {
        AppUpdateReport(
            app: InstalledApp(bundlePath: path, bundleIdentifier: path),
            sources: [
                SourceUpdate(
                    appBundlePath: path,
                    kind: .homebrew(token: "token"),
                    state: state
                )
            ],
            isSelfUpdating: isSelfUpdating
        )
    }

    /// Recompute the count the *window* shows, independently, from the same data:
    /// the sidebar's "Updates" filter keeps a report iff its per-app entry
    /// `hasUpdate`. This mirrors `AppViewModel.count(for: .updates)`.
    private func windowUpdateCount(_ reports: [AppUpdateReport]) -> Int {
        let byPath = Dictionary(uniqueKeysWithValues: reports.map { ($0.app.bundlePath, $0) })
        return reports.filter { byPath[$0.app.bundlePath]?.hasUpdate == true }.count
    }

    @Test
    func countsOnlyReportsWithAnAvailableUpdate() {
        let reports = [
            report("/Applications/A.app", state: .updateAvailable(available: "2.0", isMajor: false)),
            report("/Applications/B.app", state: .upToDate),
            report("/Applications/C.app", state: .updateAvailable(available: "3.1", isMajor: true)),
            report("/Applications/D.app", state: .unknown(.feedUnreachable)),
        ]
        #expect(MenuBarStatus.availableUpdateCount(in: reports) == 2)
    }

    @Test
    func aSelfUpdatingAppWithARealUpdateStillCounts() {
        // hasUpdate is about a detected newer version, independent of who drives
        // it — the count matches the window, which also lists it under "Updates".
        let reports = [
            report(
                "/Applications/Self.app",
                state: .updateAvailable(available: "9.0", isMajor: false),
                isSelfUpdating: true
            )
        ]
        #expect(MenuBarStatus.availableUpdateCount(in: reports) == 1)
    }

    @Test
    func menuBarCountEqualsWindowCountForMixedData() {
        let reports = [
            report("/Applications/A.app", state: .updateAvailable(available: "2.0", isMajor: false)),
            report("/Applications/B.app", state: .upToDate),
            report("/Applications/C.app", state: .unknown(.noAvailableVersion)),
            report("/Applications/D.app", state: .updateAvailable(available: "5.0", isMajor: true)),
            report(
                "/Applications/E.app", state: .updateAvailable(available: "1.1", isMajor: false), isSelfUpdating: true),
        ]
        #expect(MenuBarStatus.availableUpdateCount(in: reports) == windowUpdateCount(reports))
    }

    @Test
    func emptyAndAllUpToDateBothCountZero() {
        #expect(MenuBarStatus.availableUpdateCount(in: []) == 0)
        let allCurrent = [
            report("/Applications/A.app", state: .upToDate),
            report("/Applications/B.app", state: .unknown(.toolUnavailable)),
        ]
        #expect(MenuBarStatus.availableUpdateCount(in: allCurrent) == 0)
    }

    @Test
    func hasUpdatesReflectsTheCount() {
        #expect(MenuBarStatus(availableUpdateCount: 0).hasUpdates == false)
        #expect(MenuBarStatus(availableUpdateCount: 3).hasUpdates == true)
    }
}
