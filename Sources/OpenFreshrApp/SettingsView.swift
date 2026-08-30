import SwiftUI
import ServiceManagement
import UserNotifications
import OpenFreshrCore

/// The Settings scene.
///
/// Everything here is a preference, not an action on apps: the check cadence, the
/// menu-bar/Dock presentation, launch-at-login, optional notifications, and a way
/// to reach the trust store. It binds straight to the shared ``AppViewModel`` so
/// the menu bar and the background scheduler observe the same values.
struct SettingsView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    /// Launch-at-login is owned by the system (``SMAppService``), so it is read
    /// from and written to there rather than persisted by us. Seeded from the live
    /// status and reconciled whenever the toggle changes.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var viewModel = viewModel

        TabView {
            Form {
                Section {
                    Picker("Automatisch prüfen", selection: $viewModel.checkInterval) {
                        ForEach(UpdateCheckInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    Text("OpenFreshr prüft im Hintergrund nur auf Updates — installiert wird nie automatisch. Jede Aktualisierung läuft über die Vorschau und Bestätigung im Fenster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Hintergrundprüfung")
                }

                Section {
                    Toggle("Bei neuen Updates benachrichtigen", isOn: $viewModel.notifyOnNewUpdates)
                        .onChange(of: viewModel.notifyOnNewUpdates) { _, enabled in
                            if enabled {
                                Task { await UpdateNotifier.requestAuthorizationIfNeeded() }
                            }
                        }
                    Text("Standardmäßig aus. Ohne erteilte Systemberechtigung bleibt die Benachrichtigung still aus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Benachrichtigungen")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Prüfung", systemImage: "clock.arrow.circlepath") }

            Form {
                Section {
                    Toggle("Symbol im Dock anzeigen", isOn: $viewModel.showsDockIcon)
                    Text("Aus: OpenFreshr läuft nur in der Menüleiste, ohne Dock-Symbol. Das Schließen des Fensters beendet die App nicht — sie läuft in der Menüleiste weiter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Erscheinungsbild")
                }

                Section {
                    Toggle("Bei der Anmeldung starten", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            setLaunchAtLogin(enabled)
                        }
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Start")
                }

                Section {
                    Button {
                        openWindow(id: OpenFreshrScene.trustWindowID)
                    } label: {
                        Label("Vertrauensspeicher öffnen …", systemImage: "shield.lefthalf.filled")
                    }
                    Text("Verwalte gespeicherte Vertrauensentscheidungen (Signatur, Team-ID) pro App.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sicherheit")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 360)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    /// Register or unregister the app as a login item, degrading gracefully: an
    /// ad-hoc build (or a copy outside `/Applications`) may refuse, in which case
    /// the toggle reverts and the reason is shown rather than silently lying.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Anmeldeobjekt konnte nicht geändert werden: \(error.localizedDescription)"
            // Reflect the true system state rather than the intended one.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Delivers the optional "new updates found" notification.
///
/// Every entry point degrades silently without authorization: permission is only
/// ever requested when the user turns the toggle on, and delivery is gated on the
/// live authorization status, so a denied or ad-hoc build simply shows nothing.
enum UpdateNotifier {

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func notifyNewUpdates(count: Int) {
        guard count > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "Updates verfügbar"
            content.body = count == 1
                ? "1 App kann aktualisiert werden."
                : "\(count) Apps können aktualisiert werden."

            let request = UNNotificationRequest(
                identifier: "openfreshr.updates.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
