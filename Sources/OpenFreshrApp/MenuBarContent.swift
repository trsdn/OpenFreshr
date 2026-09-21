import AppKit
import OpenFreshrCore
import SwiftUI

/// The menu-bar icon.
///
/// It is a pure status glyph: a subtle outline when nothing is available, and a
/// filled counter (the SF Symbol number, 1…50) when updates are waiting — the
/// "counter or highlighted symbol" the spec asks for. It never carries an
/// action; acting happens in the popover and, ultimately, the window.
struct MenuBarLabel: View {

    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        let count = viewModel.menuBarUpdateCount
        if count <= 0 { return "arrow.down.circle" }
        if count <= 50 { return "\(count).circle.fill" }
        return "arrow.down.circle.fill"
    }

    private var accessibilityLabel: String {
        let count = viewModel.menuBarUpdateCount
        switch count {
        case 0: return String(localized: "OpenFreshr: no updates")
        case 1: return String(localized: "OpenFreshr: 1 update available")
        default: return String(localized: "OpenFreshr: \(count) updates available")
        }
    }
}

/// The menu-bar popover: a compact status readout and the three actions the spec
/// names — open the window, check now, quit — plus a link to Settings.
///
/// It is deliberately *not* a second execution path. There is no "update all"
/// here: every replacement still flows through the window's preview and
/// confirmation so the trust gate is never bypassed. "Open Window" simply
/// surfaces the window (pre-filtered to Updates) where that vetted flow lives.
struct MenuBarContent: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(SelfUpdateController.self) private var selfUpdate
    @Environment(\.openWindow) private var openWindow

    private static let maxListed = 8

    var body: some View {
        let status = viewModel.menuBarStatus

        VStack(alignment: .leading, spacing: 10) {
            header(status)

            Divider()

            if viewModel.appsWithAvailableUpdates.isEmpty {
                emptyOrCachedState(status)
            } else {
                updateList
            }

            Divider()

            actions
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private func header(_ status: MenuBarStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.hasUpdates ? "arrow.down.circle.fill" : "checkmark.seal")
                .foregroundStyle(status.hasUpdates ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "OpenFreshr").font(.headline)
                Text(headline(status))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status.isChecking {
                ProgressView().controlSize(.small)
            }
        }

        Text(lastCheckedText(status))
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func emptyOrCachedState(_ status: MenuBarStatus) -> some View {
        if status.availableUpdateCount > 0 {
            // We know a count from a previous session but have not re-scanned yet.
            Text("Open the window to see the details.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label("All apps are up to date.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var updateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.appsWithAvailableUpdates.prefix(Self.maxListed)) { report in
                HStack {
                    Text(report.app.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let version = availableVersion(for: report) {
                        Text(version)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.callout)
            }

            let overflow = viewModel.appsWithAvailableUpdates.count - Self.maxListed
            if overflow > 0 {
                Text("and \(overflow) more …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button {
                viewModel.listFilter = .updates
                openWindow(id: OpenFreshrScene.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Window", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await viewModel.checkNow() }
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(viewModel.menuBarStatus.isChecking)

            SettingsLink {
                Label("Settings …", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // OpenFreshr's own update, spelled out with the app name so it is
            // never mistaken for the managed-app check ("Check Now") above.
            Button {
                selfUpdate.checkFromMenu()
            } label: {
                Label("Check for OpenFreshr Updates …", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!selfUpdate.canCheck)

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit OpenFreshr", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func headline(_ status: MenuBarStatus) -> String {
        switch status.availableUpdateCount {
        case 0: return String(localized: "No updates available")
        case 1: return String(localized: "1 update available")
        default: return String(localized: "\(status.availableUpdateCount) updates available")
        }
    }

    private func lastCheckedText(_ status: MenuBarStatus) -> String {
        let cadence = String(localized: "Check: \(status.interval.label.lowercased())")
        guard let last = status.lastSuccessfulCheck else {
            return String(localized: "Not checked yet · \(cadence)")
        }
        let relative = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return String(localized: "Last checked \(relative) · \(cadence)")
    }

    private func availableVersion(for report: AppUpdateReport) -> String? {
        report.sources.first(where: { $0.state.hasUpdate })?.state.availableVersion
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
