import SwiftUI
import OpenFreshrCore

/// The top-level layout: a list of installed apps on the left, the selected
/// app's provenance, update state and adoption verdict on the right.
struct ContentView: View {

    @Environment(AppViewModel.self) private var viewModel
    @State private var showingUpdateSheet = false
    @State private var showingTrustSheet = false
    @State private var section: AppSection = .installed
    @State private var catalogModel = CatalogViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationSplitView {
            Group {
                switch section {
                case .installed:
                    InstalledListView(selection: $viewModel.selectedReportID)
                case .catalog:
                    CatalogSidebar(model: catalogModel)
                }
            }
            .navigationTitle("OpenFreshr")
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            switch section {
            case .installed:
                if let report = viewModel.selectedReport {
                    AppDetailView(report: report)
                } else {
                    ContentUnavailableView(
                        "Keine App ausgewählt",
                        systemImage: "shippingbox",
                        description: Text("Wähle links eine App, um Quellen, Updates und Adoptionsstatus zu sehen.")
                    )
                }
            case .catalog:
                if let result = catalogModel.selectedResult {
                    CatalogDetailView(result: result, model: catalogModel)
                } else {
                    ContentUnavailableView(
                        "Keine App ausgewählt",
                        systemImage: "square.grid.2x2",
                        description: Text("Suche links im Katalog und wähle eine App, um Details und Installation zu sehen.")
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Bereich", selection: $section) {
                    ForEach(AppSection.allCases) { item in
                        Label(item.label, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .help("Zwischen installierten Apps und dem Katalog wechseln")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingUpdateSheet = true
                } label: {
                    Label("Alle Updates \(updateCount > 0 ? "(\(updateCount))" : "")", systemImage: "arrow.down.circle")
                }
                .disabled(viewModel.allUpdateItems.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Neu scannen", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showingTrustSheet = true
                } label: {
                    Label("Vertrauensspeicher", systemImage: "shield.lefthalf.filled")
                }
            }
        }
        .sheet(isPresented: $showingUpdateSheet) {
            UpdateSheet()
        }
        .sheet(isPresented: $showingTrustSheet) {
            TrustManagementView()
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .task(id: catalogConfigureID) {
            await configureCatalog()
        }
        .onAppear {
            catalogModel.onInstalled = { await viewModel.scan() }
        }
    }

    /// The number of apps that offer at least one over-OpenFreshr-drivable update.
    private var updateCount: Int {
        Set(viewModel.allUpdateItems.map(\.app.bundlePath)).count
    }

    /// A stable identity for the catalog index inputs; when it changes, the
    /// catalog view model rebuilds its index off the main actor. Derived from the
    /// loaded catalog plus the installed inventory so that a fresh install (which
    /// changes the inventory) re-marks the catalog's "installiert" state.
    private var catalogConfigureID: String {
        let stamp = viewModel.loadedCatalog.map {
            "\($0.fetchedAt.timeIntervalSince1970)-\($0.casks.count)"
        } ?? "none"
        var hasher = Hasher()
        for report in viewModel.reports {
            hasher.combine(report.app.bundleName)
            for match in report.matches { hasher.combine(match.caskToken) }
        }
        hasher.combine(viewModel.installAnalytics?.count ?? 0)
        return "\(stamp)-\(hasher.finalize())"
    }

    /// Hand the catalog view model its data. A no-op until the catalog has loaded.
    private func configureCatalog() async {
        guard let catalog = viewModel.loadedCatalog else { return }
        let installedBundleNames = Set(viewModel.reports.map { $0.app.bundleName })
        let recognizedTokens = Set(viewModel.reports.flatMap { $0.matches.map(\.caskToken) })
        await catalogModel.configure(
            catalog: catalog,
            analytics: viewModel.installAnalytics,
            installedBundleNames: installedBundleNames,
            recognizedTokens: recognizedTokens
        )
    }
}

/// A thin status line: Homebrew availability, scan/update progress and the last
/// adoption or update message.
private struct StatusBar: View {

    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 12) {
            Label(
                viewModel.homebrewAvailable ? "Homebrew verfügbar" : "Homebrew nicht gefunden",
                systemImage: viewModel.homebrewAvailable ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .foregroundStyle(viewModel.homebrewAvailable ? Color.secondary : Color.orange)

            Divider().frame(height: 14)

            CatalogStatusView()

            if viewModel.isScanning {
                ProgressView().controlSize(.small)
                Text("Scan läuft …").foregroundStyle(.secondary)
            } else if viewModel.isCheckingUpdates {
                ProgressView().controlSize(.small)
                Text("Prüfe auf Updates …").foregroundStyle(.secondary)
            }

            Spacer()

            if let message = viewModel.lastUpdateMessage ?? viewModel.lastAdoptionMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The catalog provenance and refresh control: shows where the cask catalog came
/// from and how old it is, and offers "Katalog aktualisieren" with a visible
/// state (loading / current / failed with reason). A failed refresh never blocks
/// the app — the prior catalog stays in place and only the reason is surfaced.
private struct CatalogStatusView: View {

    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 8) {
            switch viewModel.catalogStatus {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Aktualisiere Katalog …").foregroundStyle(.secondary)
            case .upToDate:
                Label(viewModel.catalogProvenanceText, systemImage: catalogSymbol)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case let .failed(reason):
                Label(viewModel.catalogProvenanceText, systemImage: catalogSymbol)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
            }

            Menu {
                Button {
                    viewModel.refreshCatalog()
                } label: {
                    Label("Jetzt aktualisieren", systemImage: "arrow.clockwise")
                }
                Button {
                    viewModel.invalidateCatalogCache()
                } label: {
                    Label("Cache leeren und neu laden", systemImage: "trash")
                }
            } label: {
                Label("Katalog aktualisieren", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            } primaryAction: {
                viewModel.refreshCatalog()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isRefreshing)
            .help("Katalog aktualisieren")
        }
    }

    private var isRefreshing: Bool {
        if case .loading = viewModel.catalogStatus { return true }
        return false
    }

    /// A provenance glyph matching the catalog's origin.
    private var catalogSymbol: String {
        switch viewModel.catalogOrigin {
        case .network: return "cloud"
        case .cache: return "internaldrive"
        case .bundledSnapshot: return "shippingbox"
        case .empty, .none: return "hourglass"
        }
    }
}
