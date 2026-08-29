import SwiftUI
import OpenFreshrCore

/// The sidebar: a filter control over every scanned app as a selectable row.
struct InstalledListView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Binding var selection: AppReport.ID?

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 0) {
            Picker("Filter", selection: $viewModel.listFilter) {
                ForEach(AppListFilter.allCases) { filter in
                    Text("\(filter.label) (\(viewModel.count(for: filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(viewModel.filteredReports, selection: $selection) { report in
                InstalledRow(report: report)
                    .tag(report.id)
            }
            .overlay {
                if viewModel.filteredReports.isEmpty && !viewModel.isScanning {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                }
            }
        }
    }

    private var emptyTitle: String {
        viewModel.listFilter == .all ? "Keine Apps gefunden" : "Nichts im Filter"
    }

    private var emptyDescription: String {
        switch viewModel.listFilter {
        case .all: return "Der Scan hat keine Programme erkannt."
        case .updates: return "Für keine App wurde ein Update erkannt."
        case .selfUpdating: return "Keine App aktualisiert sich selbst."
        case .unassigned: return "Jede App ist einer Quelle zugeordnet."
        case .problems: return "Keine Quelle meldet ein Problem."
        }
    }
}

/// One app row: name, version, the available update version when known, and a
/// compact update/adoption badge.
private struct InstalledRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport

    private var update: AppUpdateReport? { viewModel.updateReport(for: report) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.app.displayName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(report.app.displayVersion.map { "Version \($0)" } ?? "Version unbekannt")
                        .foregroundStyle(.secondary)
                    if let available = availableVersion {
                        Image(systemName: "arrow.right")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text(available)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }

            Spacer()

            badge
        }
        .padding(.vertical, 2)
    }

    /// The version the most actionable source would move to, if any.
    private var availableVersion: String? {
        update?.primarySource?.state.availableVersion
    }

    @ViewBuilder
    private var badge: some View {
        if viewModel.updateInFlight.contains(report.app.bundlePath) {
            ProgressView().controlSize(.small)
        } else if let update, update.hasUpdate {
            UpdateBadge(isMajor: update.hasMajorUpdate)
        } else {
            AdoptionBadge(report: report)
        }
    }
}

/// A small capsule marking an available update; major upgrades read differently
/// so the user can spot the ones that need a separate, deliberate confirmation.
struct UpdateBadge: View {

    let isMajor: Bool

    var body: some View {
        Text(isMajor ? "Major" : "Update")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color { isMajor ? .orange : .accentColor }
}

/// A small colored capsule summarising the adoption verdict.
///
/// Three states, so a recognised-but-not-adoptable app is never mistaken for a
/// genuinely unmatched one:
///
/// * **adoptierbar** — eligible for `--adopt` (green).
/// * **erkannt** — at least one cask candidate was found but the app cannot be
///   adopted (already managed, vetoed, installer-only, identity unconfirmed …).
/// * **—** — no cask candidate at all; truly unassigned.
struct AdoptionBadge: View {

    let report: AppReport

    private enum State {
        case adoptable
        case recognized
        case unassigned
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var state: State {
        if report.eligibility.isEligible { return .adoptable }
        // A cask candidate exists but the app is not adoptable: recognised, not
        // unassigned. Uses the matches already present on the report.
        if !report.matches.isEmpty { return .recognized }
        return .unassigned
    }

    private var text: String {
        switch state {
        case .adoptable: return "adoptierbar"
        case .recognized: return "erkannt"
        case .unassigned: return "—"
        }
    }

    private var color: Color {
        switch state {
        case .adoptable: return .green
        case .recognized: return .blue
        case .unassigned: return .secondary
        }
    }
}
