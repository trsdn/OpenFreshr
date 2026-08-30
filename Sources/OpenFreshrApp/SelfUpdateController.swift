import AppKit
import Foundation
import OpenFreshrCore
#if canImport(Sparkle)
import Sparkle
#endif

/// Drives OpenFreshr's *own* update check — deliberately separate from the
/// managed-app update flow so the two can never be confused. The managed apps
/// are checked by ``AppViewModel`` and replaced only through the window's trust
/// gate; this controller only ever affects OpenFreshr itself.
///
/// Two implementations sit behind one `checkForUpdates()` entry point:
///
/// * **Release build with Sparkle linked** (`#if canImport(Sparkle)`): hands off
///   to Sparkle's `SPUStandardUpdaterController`, which verifies the release's
///   EdDSA signature against `SUPublicEDKey` before installing. This is the
///   shipping path — OpenFreshr updates itself through the same signed
///   direct-distribution channel it recognises in other apps.
/// * **Default framework-free build** (the everyday `make app`/`make run`): a
///   working fallback that reuses the UI-free ``SelfUpdateChecker`` to read the
///   appcast and, when a newer version exists, offers to open the releases page.
///   It never downloads or replaces anything itself, so it is safe without the
///   Sparkle installer.
///
/// The feed URL and current version are read straight from the bundle
/// (`SUFeedURL`, `CFBundleShortVersionString`) so there is a single source of
/// truth shared with Sparkle.
@MainActor
@Observable
final class SelfUpdateController {

    /// The running app's marketing version, for display and comparison.
    let currentVersion: String

    private let feedURL: String
    private let releasesURL: URL
    private let fetcher: any HTTPFetching

    /// `true` while the fallback check is in flight, so the menu item can disable
    /// itself. (The Sparkle path drives its own UI and leaves this `false`.)
    private(set) var isChecking = false

    #if canImport(Sparkle)
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    init(bundle: Bundle = .main, fetcher: any HTTPFetching = SystemHTTPFetcher()) {
        self.currentVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        self.releasesURL =
            URL(string: "https://github.com/trsdn/OpenFreshr/releases/latest")!
        self.fetcher = fetcher
    }

    /// Whether the check can run right now (used to disable the menu item).
    var canCheck: Bool { !isChecking }

    func checkForUpdates() {
        #if canImport(Sparkle)
        // Sparkle owns the whole experience: check, present, verify, install.
        updaterController.updater.checkForUpdates()
        #else
        guard !isChecking else { return }
        isChecking = true
        Task {
            let status = await SelfUpdateChecker.check(
                currentVersion: currentVersion,
                feedURL: feedURL,
                using: fetcher
            )
            isChecking = false
            present(status)
        }
        #endif
    }

    #if !canImport(Sparkle)
    /// Present the fallback result as a modal alert. Only ever OpenFreshr's own
    /// version is involved here — never a managed app.
    private func present(_ status: SelfUpdateStatus) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch status.availability {
        case let .updateAvailable(version):
            alert.messageText = "OpenFreshr \(version) ist verfügbar"
            alert.informativeText =
                "Installiert ist \(status.currentVersion). Die neue Version steht auf der "
                + "Releases-Seite zum Download bereit."
            alert.addButton(withTitle: "Zu den Releases …")
            alert.addButton(withTitle: "Später")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releasesURL)
            }
        case .upToDate:
            alert.messageText = "OpenFreshr ist aktuell"
            alert.informativeText = "Version \(status.currentVersion) ist die neueste verfügbare."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .unknown:
            alert.messageText = "Update-Prüfung nicht möglich"
            alert.informativeText =
                "Der Update-Feed war nicht erreichbar oder lieferte keine vergleichbare "
                + "Version. Bitte später erneut versuchen."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    #endif
}
