import SwiftUI
import OpenFreshrCore

/// The sidebar: every scanned app as a selectable row.
struct InstalledListView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Binding var selection: AppReport.ID?

    var body: some View {
        List(viewModel.reports, selection: $selection) { report in
            InstalledRow(report: report)
                .tag(report.id)
        }
        .overlay {
            if viewModel.reports.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "Keine Apps gefunden",
                    systemImage: "magnifyingglass",
                    description: Text("Der Scan hat keine Programme erkannt.")
                )
            }
        }
    }
}

/// One app row: name, version and a compact adoption badge.
private struct InstalledRow: View {

    let report: AppReport

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(report.app.displayVersion.map { "Version \($0)" } ?? "Version unbekannt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            AdoptionBadge(report: report)
        }
        .padding(.vertical, 2)
    }
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
