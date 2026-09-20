import AppKit
import AppUpdater
import Foundation
import OSLog
import OpenFreshrCore

/// Keeps OpenFreshr itself current, from its own GitHub Releases.
///
/// Backed by [AppUpdater](https://github.com/mxcl/AppUpdater), the same updater
/// OpenWritr and OpenSwitchr use. It accepts only a release asset named exactly
/// `<repository>-<semver>.dmg`, and only when the app inside carries the same
/// Developer ID Team ID, signing identifier and bundle identifier as this one, so
/// a swapped asset does not install.
///
/// GitHub artifact attestation is deliberately not required: the notarization
/// broker builds a release in its own repository, so there is no provenance from
/// `trsdn/OpenFreshr` to check, and AppUpdater's Sigstore trust roots come from
/// SwiftPM's `Bundle.module`, which an app bundle does not carry. The Developer
/// ID checks still apply.
///
/// This is deliberately separate from the managed-app update flow: the managed
/// apps are checked by ``AppViewModel`` and replaced only through the window's
/// trust gate; this controller only ever affects OpenFreshr itself. It is the only
/// thing here that talks to GitHub Releases for OpenFreshr, it is off the moment
/// automatic checks are, and a manual check is always the user's own request.
@MainActor
@Observable
final class SelfUpdateController {

    static let automaticChecksKey = "selfUpdate.automaticChecks"
    static let lastCheckKey = "selfUpdate.lastCheck"

    /// The running app's marketing version, for display.
    let currentVersion: String

    private(set) var state: SelfUpdateState = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let updater = AppUpdater(owner: "trsdn", repo: "OpenFreshr")
    @ObservationIgnored private let log = Logger(
        subsystem: "com.openfreshr.app", category: "self-update")
    @ObservationIgnored private var preparedUpdate: PreparedUpdate?
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?

    /// Runs right before the bundle is replaced, so the app can stop its own
    /// scans and background work instead of being killed mid-operation.
    @ObservationIgnored var onWillInstall: (() -> Void)?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.currentVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.defaults = defaults
    }

    /// On by default; a stored `false` is the only way it is off.
    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.automaticChecksKey)
            applyAutomaticChecksSetting()
        }
    }

    private var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    /// Whether the menu item can act right now.
    var canCheck: Bool { !state.isBusy }

    // MARK: - Automatic checks

    /// Starts (or restarts) the background loop, or stops it when the setting is
    /// off. Wakes hourly but checks at most once a day, so a Mac that sleeps
    /// through the deadline still catches up.
    func applyAutomaticChecksSetting() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
        guard automaticChecksEnabled else { return }

        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self,
                    SelfUpdateSchedule.isDue(
                        enabled: self.automaticChecksEnabled, lastCheck: self.lastCheck, now: Date())
                {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(SelfUpdateSchedule.wakeInterval))
            }
        }
    }

    func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    // MARK: - Check, install, dismiss

    /// Menu entry point: installs a downloaded update when there is one, otherwise
    /// checks and tells the person what happened.
    func checkFromMenu() {
        if case let .readyToInstall(version) = state {
            confirmInstall(version: version)
            return
        }
        Task {
            await check(userInitiated: true)
            presentOutcome()
        }
    }

    /// Looks for a newer release and, if there is one, downloads and validates it
    /// so that installing is a single click.
    func check(userInitiated: Bool) async {
        guard !state.isBusy, preparedUpdate == nil else { return }
        if userInitiated {
            state = .checking
        } else {
            lastCheck = Date()
        }

        do {
            guard let update = try await updater.check() else {
                log.info("No update available")
                state = .afterNoUpdate(userInitiated: userInitiated)
                return
            }
            log.notice("Update available: \(update.version, privacy: .public)")
            state = .downloading(version: update.version)
            preparedUpdate = try await update.prepareInstallation()
            state = .readyToInstall(version: update.version)
        } catch is CancellationError {
            state = .idle
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .afterFailure(error.localizedDescription, userInitiated: userInitiated)
        }
    }

    /// Replaces the app and relaunches it. On success this never returns.
    func installAndRelaunch() async {
        guard let prepared = preparedUpdate else { return }
        preparedUpdate = nil
        state = .installing
        stopAutomaticChecks()
        onWillInstall?()

        do {
            try await prepared.installAndRelaunch()
        } catch {
            log.error("Install failed: \(error.localizedDescription, privacy: .public)")
            state = .installFailed(error.localizedDescription)
            presentOutcome()
        }
    }

    /// Throws the downloaded update away. The next check finds it again.
    func dismiss() async {
        if let prepared = preparedUpdate {
            preparedUpdate = nil
            await prepared.discard()
        }
        state = .idle
    }

    // MARK: - Presentation

    private func presentOutcome() {
        switch state {
        case let .readyToInstall(version):
            confirmInstall(version: version)
        case .upToDate:
            alert(
                title: "OpenFreshr ist aktuell",
                text: "Version \(currentVersion) ist die neueste verfügbare.")
            state = .idle
        case let .failed(message):
            alert(title: "Update-Prüfung nicht möglich", text: message)
            state = .idle
        case let .installFailed(message):
            alert(
                title: "Installation fehlgeschlagen",
                text: "\(message)\n\nBitte OpenFreshr neu starten.")
            state = .idle
        default:
            break
        }
    }

    private func confirmInstall(version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OpenFreshr \(version) ist bereit"
        alert.informativeText =
            "Installiert ist \(currentVersion). OpenFreshr wird ersetzt und startet neu."
        alert.addButton(withTitle: "Installieren und neu starten")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await installAndRelaunch() }
        }
    }

    private func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
