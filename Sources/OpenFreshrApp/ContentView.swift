import SwiftUI
import OpenFreshrCore

/// The top-level layout: a list of installed apps on the left, the selected
/// app's provenance and adoption verdict on the right.
struct ContentView: View {

    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationSplitView {
            InstalledListView(selection: $viewModel.selectedReportID)
                .navigationTitle("OpenFreshr")
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let report = viewModel.selectedReport {
                AppDetailView(report: report)
            } else {
                ContentUnavailableView(
                    "Keine App ausgewählt",
                    systemImage: "shippingbox",
                    description: Text("Wähle links eine App, um Quellen und Adoptionsstatus zu sehen.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Neu scannen", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
    }
}

/// A thin status line: Homebrew availability, catalog age and the last adoption
/// message.
private struct StatusBar: View {

    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 12) {
            Label(
                viewModel.homebrewAvailable ? "Homebrew verfügbar" : "Homebrew nicht gefunden",
                systemImage: viewModel.homebrewAvailable ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .foregroundStyle(viewModel.homebrewAvailable ? Color.secondary : Color.orange)

            if viewModel.isScanning {
                ProgressView().controlSize(.small)
                Text("Scan läuft …").foregroundStyle(.secondary)
            }

            Spacer()

            if let message = viewModel.lastAdoptionMessage {
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
