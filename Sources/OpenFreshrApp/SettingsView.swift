import OpenFreshrCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// The Settings scene.
///
/// Everything here is a preference, not an action on apps: the check cadence, the
/// menu-bar/Dock presentation, launch-at-login, optional notifications, and a way
/// to reach the trust store. It binds straight to the shared ``AppViewModel`` so
/// the menu bar and the background scheduler observe the same values.
struct SettingsView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(SelfUpdateController.self) private var selfUpdate
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
                    Picker("Check automatically", selection: $viewModel.checkInterval) {
                        ForEach(UpdateCheckInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    Text(
                        "OpenFreshr only checks for updates in the background — nothing is ever installed automatically. Every update goes through the preview and confirmation in the window."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Background Check")
                }

                Section {
                    Toggle("Notify about new updates", isOn: $viewModel.notifyOnNewUpdates)
                        .onChange(of: viewModel.notifyOnNewUpdates) { _, enabled in
                            if enabled {
                                Task { await UpdateNotifier.requestAuthorizationIfNeeded() }
                            }
                        }
                    Text("Off by default. Without the granted system permission, the notification stays silent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Notifications")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Checking", systemImage: "clock.arrow.circlepath") }

            Form {
                Section {
                    Toggle("Show icon in the Dock", isOn: $viewModel.showsDockIcon)
                    Text(
                        "Off: OpenFreshr runs only in the menu bar, without a Dock icon. Closing the window does not quit the app — it keeps running in the menu bar."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            setLaunchAtLogin(enabled)
                        }
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Startup")
                }

                Section {
                    Toggle(
                        "Update OpenFreshr automatically",
                        isOn: Binding(
                            get: { selfUpdate.automaticChecksEnabled },
                            set: { selfUpdate.automaticChecksEnabled = $0 }
                        ))
                    Text(
                        "Checks GitHub at most once a day for a new version of OpenFreshr. Nothing is installed until you confirm."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Self-Update")
                }

                Section {
                    Button {
                        openWindow(id: OpenFreshrScene.trustWindowID)
                    } label: {
                        Label("Open Trust Store …", systemImage: "shield.lefthalf.filled")
                    }
                    Text("Manage stored trust decisions (signature, team ID) per app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Security")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Picker("Agent", selection: $viewModel.aiAgentKind) {
                        ForEach(AIAgentKind.allCases) { agent in
                            Text(agent.label).tag(agent)
                        }
                    }
                    .onChange(of: viewModel.aiAgentKind) { _, newValue in
                        if viewModel.aiAgentExtraArguments.isEmpty {
                            viewModel.aiAgentExtraArguments = newValue.defaultAutonomyArguments.joined(
                                separator: " ")
                        }
                    }
                    Text(
                        "Off by default. For an app OpenFreshr cannot update itself, \"Update with AI\" hands that one app to this CLI and lets it act on its own, without asking before each step. It runs as you, never with more access than you already have — OpenFreshr does not check what it does, and only confirms afterward, by looking again, whether the app actually changed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Update with AI")
                }

                if viewModel.aiAgentKind != .none {
                    Section {
                        LabeledContent("Status") {
                            Text(agentStatusText)
                                .foregroundStyle(viewModel.isAIAgentAvailable() ? Color.secondary : Color.orange)
                        }
                        TextField("Custom path", text: customPathBinding)
                            .textFieldStyle(.roundedBorder)
                        Text("Only needed when the CLI is not found automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Location")
                    }

                    Section {
                        TextField("Arguments", text: $viewModel.aiAgentExtraArguments)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text(
                            "Appended after the prompt. Starts at the one flag that lets the agent act without asking each time; edit or clear it to change what it is allowed to do."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Arguments")
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 520)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var agentStatusText: String {
        viewModel.isAIAgentAvailable()
            ? String(localized: "Found") : String(localized: "Not found on this Mac")
    }

    private var customPathBinding: Binding<String> {
        Binding(
            get: { viewModel.aiAgentCustomPaths[viewModel.aiAgentKind] ?? "" },
            set: { newValue in
                var paths = viewModel.aiAgentCustomPaths
                if newValue.isEmpty {
                    paths.removeValue(forKey: viewModel.aiAgentKind)
                } else {
                    paths[viewModel.aiAgentKind] = newValue
                }
                viewModel.aiAgentCustomPaths = paths
            }
        )
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
            loginItemError = String(localized: "Login item could not be changed: \(error.localizedDescription)")
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
            guard
                settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Updates available")
            content.body =
                count == 1
                ? String(localized: "1 app can be updated.")
                : String(localized: "\(count) apps can be updated.")

            let request = UNNotificationRequest(
                identifier: "openfreshr.updates.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
