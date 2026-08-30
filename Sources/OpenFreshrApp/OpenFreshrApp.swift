import SwiftUI
import AppKit

/// Stable scene identifiers, shared by the scenes and the actions that open them
/// (the menu bar's "Fenster öffnen", Settings' "Vertrauensspeicher öffnen").
enum OpenFreshrScene {
    static let mainWindowID = "main"
    static let trustWindowID = "trust"
}

/// The application entry point.
///
/// Phase 6 turns OpenFreshr from a pure window app into a menu-bar-first updater:
/// a ``MenuBarExtra`` reports available updates at a glance, a background loop
/// checks on a cadence (only checking — never installing), and a ``Settings``
/// scene exposes the cadence, the menu-bar/Dock mode, launch-at-login and the
/// trust store. The window keeps the *only* path that changes an app, so the
/// trust gate and preview are never bypassed.
@main
struct OpenFreshrApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: OpenFreshrScene.mainWindowID) {
            ContentView()
                .environment(appDelegate.viewModel)
                .frame(minWidth: 820, minHeight: 520)
                .task { await appDelegate.viewModel.scanOnWindowAppear() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.viewModel)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.viewModel)
        }

        Window("Vertrauensspeicher", id: OpenFreshrScene.trustWindowID) {
            TrustManagementView()
                .environment(appDelegate.viewModel)
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

/// Owns the shared ``AppViewModel`` and everything that must live at the
/// application (not scene) level: the Dock-vs-menu-bar activation policy, the
/// background check loop, and the "closing the window does not quit" behaviour.
///
/// The view model is created here — rather than as `@State` on the `App` — so it
/// has a stable owner independent of any window, which is what lets the app run
/// with no window at all in menu-bar-only mode.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let viewModel = AppViewModel()
    private var periodicCheck: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy(showsDockIcon: viewModel.showsDockIcon)

        // The view model stays AppKit-free; it calls back here to apply the Dock
        // policy and to deliver notifications.
        viewModel.onShowsDockIconChange = { [weak self] showsDockIcon in
            self?.applyActivationPolicy(showsDockIcon: showsDockIcon)
        }
        viewModel.onNewUpdatesDetected = { count in
            UpdateNotifier.notifyNewUpdates(count: count)
        }

        // In menu-bar-only mode, dismiss the window WindowGroup auto-opens at
        // launch so the app truly starts headless. The user reopens it from the
        // menu bar when needed — and that reopen *should* scan, so clear the
        // one-shot suppression once the throwaway window is gone.
        if !viewModel.showsDockIcon {
            DispatchQueue.main.async { [viewModel] in
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
                viewModel.suppressNextWindowScan = false
            }
        }

        startPeriodicCheck()
    }

    /// Closing the last window must not quit the app: it keeps running in the menu
    /// bar (and reopens the window on demand). This holds in both modes because the
    /// menu bar is always present.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon (regular mode) with no window open reopens the main
    /// window rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    private func applyActivationPolicy(showsDockIcon: Bool) {
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }

    /// Drive the background cadence. The *decision* to check lives in the core
    /// (``AppViewModel/runScheduledCheckIfDue(now:)`` over the injectable schedule);
    /// this loop only supplies real time and sleeps exactly as long as the schedule
    /// says, waking at least hourly to re-evaluate after an interval change or a
    /// long system sleep. `Task.sleep` is fine here — it is the driver, not the
    /// tested logic.
    private func startPeriodicCheck() {
        periodicCheck?.cancel()
        periodicCheck = Task { [viewModel] in
            await viewModel.runScheduledCheckIfDue()
            while !Task.isCancelled {
                let seconds = viewModel.secondsUntilNextScheduledCheck() ?? 3_600
                let clamped = min(max(seconds, 60), 3_600)
                try? await Task.sleep(for: .seconds(clamped))
                if Task.isCancelled { break }
                await viewModel.runScheduledCheckIfDue()
            }
        }
    }
}
