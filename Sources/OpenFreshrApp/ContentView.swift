import AppKit
import OpenFreshrCore
import SwiftUI

/// The window: one list that answers two questions, is there a new version and
/// what do I have to do about it.
///
/// Nothing else lives here on purpose. What an update is made of, which package
/// manager runs it and how it is verified stay in the core; a person only needs to
/// see the app, the version change and one button.
struct ContentView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openSettings) private var openSettings
    @State private var showUpToDate = false
    @State private var showNotChecked = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    // MARK: - Data

    private var groups: [UpdateBucket: [AppReport]] {
        Dictionary(uniqueKeysWithValues: viewModel.bucketedReports.map { ($0.bucket, $0.reports) })
    }

    private var actionable: [(report: AppReport, bucket: UpdateBucket)] {
        [UpdateBucket.ready, .ownUpdater, .manual].flatMap { bucket in
            (groups[bucket] ?? []).map { (report: $0, bucket: bucket) }
        }
    }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCheckingUpdates }

    /// What "Update All" would run: updates OpenFreshr can install, without the ones
    /// that change the major version. Those are updated one by one, on purpose.
    private var batchItems: [UpdateItem] {
        viewModel.allUpdateItems.filter { !$0.isMajor && viewModel.isDefaultSelectable($0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            if !batchItems.isEmpty {
                Button("Update All (\(batchItems.count))") {
                    Task { await viewModel.performUpdates(batchItems) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !viewModel.updateInFlight.isEmpty)
                .help("Install every update OpenFreshr can install")
            }
            Button("Check Again") {
                Task { await viewModel.scan() }
            }
            .disabled(isBusy)
            .help("Look for new versions now")
            Button("Settings") { openSettings() }
                .help("Open OpenFreshr's settings")
        }
        .padding(16)
    }

    private var title: String {
        if viewModel.reports.isEmpty || (isBusy && !viewModel.hasCompletedUpdateCheck) {
            return String(localized: "Checking your apps …")
        }
        switch actionable.count {
        case 0: return String(localized: "Everything is up to date")
        case 1: return String(localized: "1 update available")
        case let count: return String(localized: "\(count) updates available")
        }
    }

    private var subtitle: String? {
        if let message = viewModel.lastUpdateMessage { return message }
        if let checked = viewModel.lastSuccessfulCheck {
            return String(
                localized: "Last checked \(checked.formatted(date: .omitted, time: .shortened))")
        }
        return nil
    }

    // MARK: - List

    private var list: some View {
        List {
            if !actionable.isEmpty {
                Section {
                    ForEach(actionable, id: \.report.id) { entry in
                        UpdateRow(report: entry.report, bucket: entry.bucket)
                    }
                }
            }

            collapsible(.upToDate, isExpanded: $showUpToDate, title: "Up to date (\(count(.upToDate)))")

            collapsible(
                .cannotTell, isExpanded: $showNotChecked, title: "Can't be checked (\(count(.cannotTell)))",
                footer: "OpenFreshr does not know where to look for updates for these apps.")
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.reports.isEmpty && !viewModel.isScanning {
                ContentUnavailableView(
                    "No apps found",
                    systemImage: "magnifyingglass",
                    description: Text("The scan did not detect any apps.")
                )
            }
        }
    }

    private func count(_ bucket: UpdateBucket) -> Int { groups[bucket]?.count ?? 0 }

    @ViewBuilder
    private func collapsible(
        _ bucket: UpdateBucket, isExpanded: Binding<Bool>, title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil
    ) -> some View {
        if let reports = groups[bucket], !reports.isEmpty {
            Section(isExpanded: isExpanded) {
                ForEach(reports) { report in
                    HStack(spacing: 10) {
                        AppIcon(path: report.app.bundlePath, size: 24)
                        Text(report.app.displayName)
                        Spacer()
                        Text(report.app.displayVersion ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if let footer {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(title)
            }
        }
    }
}

/// The app's own icon, so a row is recognisable at a glance.
private struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One app with a newer version: its icon, the version change, and the one thing to
/// do about it.
private struct UpdateRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport
    let bucket: UpdateBucket

    private var update: AppUpdateReport? { viewModel.updateReport(for: report) }
    private var path: String { report.app.bundlePath }
    private var isUpdating: Bool { viewModel.updateInFlight.contains(path) }
    private var isMajor: Bool { update?.hasMajorUpdate == true }
    @State private var confirmingMajor = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: path, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.app.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(versionChange)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.failedOutcome(for: path), let problem = viewModel.updateOutcomes[path] {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }

            Spacer()

            if isUpdating {
                ProgressView().controlSize(.small)
                Text("Updating …").foregroundStyle(.secondary)
            } else if bucket == .ready {
                Button("Update") {
                    if isMajor { confirmingMajor = true } else { install() }
                }
                .buttonStyle(.borderedProminent)
                .confirmationDialog(
                    "Update \(report.app.displayName) to a new major version?",
                    isPresented: $confirmingMajor
                ) {
                    Button("Update") { install() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("A new major version can change how the app works.")
                }
                .help("Install the new version of \(report.app.displayName)")
            } else {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .help("Open \(report.app.displayName) to update it there")
            }
        }
        .padding(.vertical, 4)
    }

    private func install() {
        guard let update, let source = update.sources.first(where: { $0.isDrivable }) else { return }
        Task { await viewModel.update(update, source: source) }
    }

    private var versionChange: String {
        let installed = report.app.displayVersion ?? "?"
        guard let available = update?.primarySource?.state.availableVersion else { return installed }
        return "\(installed) → \(available)"
    }

    /// What to do when a button cannot do it for the person.
    private var hint: String? {
        switch bucket {
        case .ownUpdater: return String(localized: "Open the app and check for updates.")
        case .manual: return String(localized: "Update it in the app or on the vendor's website.")
        default: return update?.hasMajorUpdate == true ? String(localized: "New major version") : nil
        }
    }
}
