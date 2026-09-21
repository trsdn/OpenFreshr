import OpenFreshrCore
import SwiftUI

/// The sidebar: every app, grouped by what a person wants to know about it. What
/// OpenFreshr can update for them comes first; what is already fine comes last
/// and starts collapsed.
struct InstalledListView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Binding var selection: AppReport.ID?
    @State private var collapsed: Set<UpdateBucket> = [.upToDate, .cannotTell]

    var body: some View {
        List(selection: $selection) {
            ForEach(viewModel.bucketedReports, id: \.bucket) { group in
                Section(isExpanded: expansion(of: group.bucket)) {
                    ForEach(group.reports) { report in
                        InstalledRow(report: report, bucket: group.bucket)
                            .tag(report.id)
                    }
                } header: {
                    BucketHeader(bucket: group.bucket, count: group.reports.count)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.reports.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "No apps found",
                    systemImage: "magnifyingglass",
                    description: Text("The scan did not detect any apps.")
                )
            } else if viewModel.reports.isEmpty {
                ProgressView("Looking for apps …")
            }
        }
    }

    private func expansion(of bucket: UpdateBucket) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(bucket) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(bucket) } else { collapsed.insert(bucket) }
            }
        )
    }
}

extension UpdateBucket {

    /// The group heading, in the words a person would use.
    var title: String {
        switch self {
        case .ready: return String(localized: "Ready to update")
        case .updatesItself: return String(localized: "Updates itself")
        case .manual: return String(localized: "Needs you")
        case .cannotTell: return String(localized: "Can't tell")
        case .upToDate: return String(localized: "Up to date")
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "arrow.down.circle.fill"
        case .updatesItself: return "arrow.triangle.2.circlepath"
        case .manual: return "hand.raised.fill"
        case .cannotTell: return "questionmark.circle"
        case .upToDate: return "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .accentColor
        case .updatesItself: return .blue
        case .manual: return .orange
        case .cannotTell: return .secondary
        case .upToDate: return .green
        }
    }

    /// One sentence under the heading for the groups whose meaning is not obvious.
    var explanation: String? {
        switch self {
        case .ready: return nil
        case .updatesItself:
            return String(
                localized: "A newer version exists. The app has its own updater, so OpenFreshr leaves it alone.")
        case .manual:
            return String(localized: "A newer version exists, but OpenFreshr cannot install it for you.")
        case .cannotTell:
            return String(
                localized: "No source could say whether these have an update. That does not mean they are current.")
        case .upToDate: return nil
        }
    }
}

private struct BucketHeader: View {
    let bucket: UpdateBucket
    let count: Int

    var body: some View {
        Label {
            Text(verbatim: "\(bucket.title) (\(count))")
        } icon: {
            Image(systemName: bucket.symbol).foregroundStyle(bucket.color)
        }
        .font(.subheadline.weight(.semibold))
        .help(bucket.explanation ?? "")
    }
}

/// One app row: name, the version change, and one plain-language line saying where
/// the update comes from or why nothing happens.
private struct InstalledRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport
    let bucket: UpdateBucket

    private var update: AppUpdateReport? { viewModel.updateReport(for: report) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.app.displayName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(installedVersion)
                        .foregroundStyle(.secondary)
                    if let available = update?.primarySource?.state.availableVersion, bucket != .upToDate {
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text(available)
                            .foregroundStyle(bucket.color)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                if let line = detailLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if viewModel.updateInFlight.contains(report.app.bundlePath) {
                ProgressView().controlSize(.small)
            } else if let update, update.hasMajorUpdate {
                UpdateBadge(isMajor: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var installedVersion: String {
        report.app.displayVersion.map { String(localized: "Version \($0)") } ?? String(localized: "Version unknown")
    }

    /// Where the update comes from, or why it is not simply installed.
    private var detailLine: String? {
        guard let update else { return nil }
        switch bucket {
        case .ready:
            return update.primarySource?.backend.map { String(localized: "via \($0.label)") }
        case .updatesItself:
            return String(localized: "Updates itself when you open it")
        case .manual:
            switch update.manualReason {
            case .homebrewCannotTakeOver?:
                return String(localized: "Homebrew cannot take this app over. Update it at the vendor.")
            case .noAutomaticWay?, nil:
                return String(localized: "No automatic way to update it")
            }
        case .cannotTell:
            if update.isUnassigned { return String(localized: "No update source found") }
            if update.hasSourceProblem { return String(localized: "The update source did not answer") }
            return String(localized: "Nothing to compare against")
        case .upToDate:
            return nil
        }
    }
}

/// A small capsule marking an available update; major upgrades read differently
/// so the user can spot the ones that need a separate, deliberate confirmation.
struct UpdateBadge: View {

    let isMajor: Bool

    var body: some View {
        Text(isMajor ? String(localized: "Major") : String(localized: "Update"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color { isMajor ? .orange : .accentColor }
}
