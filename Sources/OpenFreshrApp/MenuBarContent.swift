import SwiftUI
import AppKit
import OpenFreshrCore

/// The menu-bar icon.
///
/// It is a pure status glyph: a subtle outline when nothing is available, and a
/// filled counter (the SF Symbol number, 1…50) when updates are waiting — the
/// "Zähler bzw. hervorgehobenes Symbol" the spec asks for. It never carries an
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
        case 0: return "OpenFreshr: keine Updates"
        case 1: return "OpenFreshr: 1 Update verfügbar"
        default: return "OpenFreshr: \(count) Updates verfügbar"
        }
    }
}

/// The menu-bar popover: a compact status readout and the three actions the spec
/// names — open the window, check now, quit — plus a link to Settings.
///
/// It is deliberately *not* a second execution path. There is no "update all"
/// here: every replacement still flows through the window's preview and
/// confirmation so the trust gate is never bypassed. "Fenster öffnen" simply
/// surfaces the window (pre-filtered to Updates) where that vetted flow lives.
struct MenuBarContent: View {

    @Environment(AppViewModel.self) private var viewModel
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
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenFreshr").font(.headline)
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
            Text("Öffne das Fenster, um die Details zu sehen.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label("Alle Apps sind aktuell.", systemImage: "checkmark.circle")
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
                Text("und \(overflow) weitere …")
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
                Label("Fenster öffnen", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await viewModel.checkNow() }
            } label: {
                Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(viewModel.menuBarStatus.isChecking)

            SettingsLink {
                Label("Einstellungen …", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("OpenFreshr beenden", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func headline(_ status: MenuBarStatus) -> String {
        switch status.availableUpdateCount {
        case 0: return "Keine Updates verfügbar"
        case 1: return "1 Update verfügbar"
        default: return "\(status.availableUpdateCount) Updates verfügbar"
        }
    }

    private func lastCheckedText(_ status: MenuBarStatus) -> String {
        let cadence = "Prüfung: \(status.interval.label.lowercased())"
        guard let last = status.lastSuccessfulCheck else {
            return "Noch nicht geprüft · \(cadence)"
        }
        let relative = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return "Zuletzt geprüft \(relative) · \(cadence)"
    }

    private func availableVersion(for report: AppUpdateReport) -> String? {
        report.sources.first(where: { $0.state.hasUpdate })?.state.availableVersion
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
}
