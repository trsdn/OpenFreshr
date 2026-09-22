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

    private var outdatedPackages: [OutdatedPackage] {
        viewModel.ecosystemReports.flatMap(\.check.packages)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

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
        switch actionable.count + outdatedPackages.count {
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

            if !outdatedPackages.isEmpty {
                Section {
                    ForEach(outdatedPackages) { package in
                        PackageRow(package: package)
                    }
                } header: {
                    Text("Packages")
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

    /// A section with its own clickable header, not `Section(isExpanded:)`: on
    /// macOS that control only draws a working disclosure triangle under
    /// `.listStyle(.sidebar)`, and this list uses `.inset` — under `.inset` the
    /// section quietly has no way to open it at all. A plain button always works,
    /// regardless of list style.
    @ViewBuilder
    private func collapsible(
        _ bucket: UpdateBucket, isExpanded: Binding<Bool>, title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil
    ) -> some View {
        if let reports = groups[bucket], !reports.isEmpty {
            Section {
                if isExpanded.wrappedValue {
                    ForEach(reports) { report in
                        SimpleAppRow(report: report)
                    }
                    if let footer {
                        Text(footer).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            .imageScale(.small)
                        Text(title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isExpanded.wrappedValue
                        ? String(localized: "Collapse") : String(localized: "Expand"))
            }
        }
    }
}

/// One app in the plain "Up to date" / "Can't be checked" lists: its icon, name
/// and version, plus Uninstall when OpenFreshr has confirmed Homebrew already
/// manages it — the one action these apps still have, even with no update to
/// offer.
private struct SimpleAppRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport

    private var path: String { report.app.bundlePath }
    private var isUninstalling: Bool { viewModel.uninstallInFlight.contains(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIcon(path: path, size: 24)
                Text(report.app.displayName)
                Spacer()
                Text(report.app.displayVersion ?? "")
                    .foregroundStyle(.secondary)
                if isUninstalling {
                    ProgressView().controlSize(.small)
                } else if report.managedCaskToken != nil {
                    UninstallButton(report: report)
                }
            }
            .font(.callout)
            if let problem = viewModel.uninstallOutcomes[path] {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
            }
        }
    }
}

/// One outdated command-line package: its name, the version change, and one
/// button. No icon — a package has none — a small symbol for its ecosystem does
/// the same job of grouping at a glance.
private struct PackageRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let package: OutdatedPackage

    private var isUpdating: Bool { viewModel.updateInFlight.contains(package.id) }
    private var canAutomaticallyUpdate: Bool { viewModel.canAutomaticallyUpdate(package) }
    private var problem: String? {
        guard let message = viewModel.updateOutcomes[package.id], message != Self.updatedMessage else {
            return nil
        }
        return message
    }
    private static var updatedMessage: String { String(localized: "Updated and confirmed.") }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(package.ecosystem.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(versionChange)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let description = package.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !canAutomaticallyUpdate {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(6)
                }
            }

            Spacer()

            if isUpdating {
                ProgressView().controlSize(.small)
                Text("Updating …").foregroundStyle(.secondary)
            } else if canAutomaticallyUpdate {
                Button("Update") {
                    Task { await viewModel.updatePackage(package) }
                }
                .buttonStyle(.borderedProminent)
                .help("Install the new version of \(package.name)")
            } else {
                Button("Open") {
                    openWhereToUpdate()
                }
                .help("Open where \(package.name) can be updated")
            }
        }
        .padding(.vertical, 4)
    }

    private var versionChange: String {
        package.installed.isEmpty ? package.available : "\(package.installed) → \(package.available)"
    }

    private var hint: String {
        package.ecosystem == .macOS
            ? String(localized: "Install it in System Settings.")
            : String(localized: "OpenFreshr does not install this automatically.")
    }

    private func openWhereToUpdate() {
        guard package.ecosystem == .macOS,
            let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Removes an app OpenFreshr has confirmed Homebrew already manages (#40).
/// Offered next to whatever other action a row has, never in its place — a
/// managed app in `.ready`/`.ownUpdater`/`.manual` can still be updated *or*
/// removed, so this never crowds the update path out.
///
/// The caller (``UpdateRow``, ``SimpleAppRow``) checks
/// `report.managedCaskToken != nil` before showing this and shows its own
/// progress state while ``AppViewModel/uninstallInFlight`` holds the app's
/// bundle path — never both a spinner and this button on screen together.
private struct UninstallButton: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport
    @State private var confirming = false

    var body: some View {
        Button("Uninstall", role: .destructive) {
            confirming = true
        }
        .confirmationDialog(
            "Uninstall \(report.app.displayName)?",
            isPresented: $confirming
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await viewModel.uninstall(report) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes it via Homebrew (brew uninstall). This does not touch its settings or documents."
            )
        }
        .help("Remove \(report.app.displayName) via Homebrew")
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
    @State private var confirmingAI = false

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
                if let website = viewModel.websiteURL(for: report) {
                    Link("Website", destination: website)
                        .font(.caption)
                        .help("Open the website of \(report.app.displayName)")
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.failedOutcome(for: path), let problem = viewModel.updateOutcomes[path] {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(6)
                }
                if let problem = viewModel.uninstallOutcomes[path] {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(6)
                }
            }

            Spacer()

            if isUpdating {
                ProgressView().controlSize(.small)
                Text("Updating …").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if viewModel.isAIAgentAvailable() {
                        aiButton
                    }
                    if bucket == .ready {
                        updateButton
                    } else {
                        openButton
                    }
                    if viewModel.uninstallInFlight.contains(path) {
                        ProgressView().controlSize(.small)
                    } else if report.managedCaskToken != nil {
                        UninstallButton(report: report)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var updateButton: some View {
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
    }

    private var openButton: some View {
        Button("Open") {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .help("Open \(report.app.displayName) to update it there")
    }

    /// Offered for every bucket, not only `.manual`: a person may prefer the
    /// agent over OpenFreshr's own path, or over an app's own updater, and — for
    /// a `.ready` app whose own command just failed (a trust block, a sudo
    /// refusal) — may choose it anyway, having already read why OpenFreshr would
    /// not. That reading is what keeps this an informed choice rather than a
    /// hidden bypass: the trust or failure message above stays visible right next
    /// to this button, never replaced by it.
    private var aiButton: some View {
        Button("Update with AI") {
            confirmingAI = true
        }
        .confirmationDialog(
            "Let \(viewModel.aiAgentKind.label) try to update \(report.app.displayName)?",
            isPresented: $confirmingAI
        ) {
            Button("Update with AI") { updateWithAI() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "It runs on its own, as you, without asking before each step. OpenFreshr does not check what it does, and only confirms afterward whether the app actually changed."
            )
        }
        .help("Let \(viewModel.aiAgentKind.label) try to update \(report.app.displayName)")
    }

    private func install() {
        guard let update, let source = update.sources.first(where: { $0.isDrivable }) else { return }
        Task { await viewModel.update(update, source: source) }
    }

    private func updateWithAI() {
        guard let update else { return }
        Task { await viewModel.updateWithAI(update, bucket: bucket) }
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
