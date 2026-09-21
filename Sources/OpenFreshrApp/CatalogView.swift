import OpenFreshrCore
import SwiftUI

/// Which main area the window shows: the installed inventory (phases 1–4) or the
/// catalog of installable apps (phase 5). A plain, additive switch so the two
/// areas share one `NavigationSplitView` without disturbing each other.
enum AppSection: String, CaseIterable, Identifiable {
    case installed
    case catalog

    var id: String { rawValue }

    var label: String {
        switch self {
        case .installed: return String(localized: "Installed")
        case .catalog: return String(localized: "Catalog")
        }
    }

    var symbol: String {
        switch self {
        case .installed: return "shippingbox"
        case .catalog: return "square.grid.2x2"
        }
    }
}

/// The catalog sidebar: a search field over the whole cask catalog and a ranked,
/// selectable result list. The expensive work is the view model's; this view
/// only binds the query and renders rows.
struct CatalogSidebar: View {

    @Bindable var model: CatalogViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search apps in the catalog", text: $model.query)
                    .textFieldStyle(.plain)
                    .onChange(of: model.query) { _, _ in model.search() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            statusLine
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()

            List(model.results, selection: $model.selectedTokenID) { result in
                CatalogRow(result: result, model: model)
                    .tag(result.id)
            }
            .overlay {
                if model.results.isEmpty && !model.isIndexing {
                    ContentUnavailableView(
                        model.indexCount == 0 ? String(localized: "Loading catalog") : String(localized: "No matches"),
                        systemImage: "magnifyingglass",
                        description: Text(
                            model.indexCount == 0
                                ? String(localized: "Once the cask catalog is loaded, you can search here.")
                                : String(localized: "No app matches “\(model.query)”.")
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if model.isIndexing {
                ProgressView().controlSize(.small)
                Text("Building search index …")
            } else if model.matchCount > model.results.count {
                Text("\(model.results.count) of \(model.matchCount.formatted()) matches")
            } else if model.query.isEmpty {
                Text("\(model.indexCount.formatted()) apps searchable")
            } else {
                Text("\(model.matchCount.formatted()) matches")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One catalog row: name, one-line description, popularity, and an "installiert"
/// or install-outcome marker.
private struct CatalogRow: View {

    let result: CatalogSearchResult
    let model: CatalogViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.isInstallerOnly ? "shippingbox" : "app")
                .accessibilityHidden(true)
                .foregroundStyle(.secondary)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                    .font(.body)
                    .lineLimit(1)
                if let desc = result.cask.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(result.cask.token)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let count = result.installCount {
                    Label("\(count.formatted()) installs/year", systemImage: "chart.bar.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.installInFlight.contains(result.cask.token) {
            ProgressView().controlSize(.small)
        } else if let outcome = model.installOutcomes[result.cask.token] {
            Image(systemName: outcomeSymbol(outcome.state))
                .foregroundStyle(outcomeColor(outcome.state))
                .help(outcome.text)
                .accessibilityLabel(outcome.text)
        } else if result.isInstalled {
            CatalogInstalledBadge()
        }
    }

    private func outcomeSymbol(_ state: CatalogInstallOutcome.State) -> String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func outcomeColor(_ state: CatalogInstallOutcome.State) -> Color {
        switch state {
        case .success: return .green
        case .info: return .secondary
        case .failure: return .orange
        }
    }
}

/// A small capsule marking a catalog entry the machine already has.
struct CatalogInstalledBadge: View {
    var body: some View {
        Text("installed")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
    }
}

/// The catalog detail pane: everything known about the selected cask plus the
/// install action (gated behind the preview sheet).
struct CatalogDetailView: View {

    @Environment(AppViewModel.self) private var appViewModel
    let result: CatalogSearchResult
    let model: CatalogViewModel

    @State private var showingInstallSheet = false

    private var cask: Cask { result.cask }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let desc = cask.desc, !desc.isEmpty {
                    Text(desc).font(.body)
                }

                factGrid

                if result.isInstalled {
                    Label(
                        result.installedBundleName.map { String(localized: "Already installed as \($0).") }
                            ?? String(localized: "This app is already recognized as installed."),
                        systemImage: "checkmark.seal"
                    )
                    .foregroundStyle(.green)
                    .font(.callout)
                }

                if result.isInstallerOnly {
                    Label(
                        "Installer cask: installs via a pkg/installer with an authorization prompt, not via a simple app bundle.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }

                if let outcome = model.installOutcomes[cask.token] {
                    Label(outcome.text, systemImage: outcomeSymbol(outcome.state))
                        .foregroundStyle(outcomeColor(outcome.state))
                        .font(.callout)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInstallSheet = true
                } label: {
                    Label("Install", systemImage: "arrow.down.app")
                }
                .disabled(!appViewModel.homebrewAvailable || model.installInFlight.contains(cask.token))
            }
        }
        .sheet(isPresented: $showingInstallSheet) {
            InstallSheet(result: result, model: model)
                .environment(appViewModel)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: result.isInstallerOnly ? "shippingbox.fill" : "app.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName).font(.title2.bold())
                Text(cask.token)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.installInFlight.contains(cask.token) {
                ProgressView().controlSize(.small)
            } else if result.isInstalled {
                CatalogInstalledBadge()
            }
        }
    }

    private var factGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            fact("Version", cask.version ?? String(localized: "unknown"))
            fact("Type", artifactLabel)
            fact(
                "Popularity",
                result.installCount.map { String(localized: "\($0.formatted()) installs/year") }
                    ?? String(localized: "unknown"))
            if let homepage = cask.homepage, let url = URL(string: homepage) {
                GridRow {
                    Text("Homepage").foregroundStyle(.secondary)
                    Link(homepage, destination: url).lineLimit(1)
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// A human label for the cask's primary artifact kind.
    private var artifactLabel: String {
        if cask.artifacts.contains(where: { $0.kind == .suite }) { return String(localized: "Suite (app bundle)") }
        if cask.artifacts.contains(where: { $0.kind == .app }) { return String(localized: "App bundle") }
        if cask.artifacts.contains(where: { $0.kind == .pkg }) { return String(localized: "pkg installer") }
        if cask.artifacts.contains(where: { $0.kind == .installer }) { return String(localized: "Installer") }
        if cask.artifacts.contains(where: { $0.kind == .binary }) { return String(localized: "Binary") }
        return String(localized: "other artifact")
    }

    private func outcomeSymbol(_ state: CatalogInstallOutcome.State) -> String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func outcomeColor(_ state: CatalogInstallOutcome.State) -> Color {
        switch state {
        case .success: return .green
        case .info: return .secondary
        case .failure: return .orange
        }
    }
}
