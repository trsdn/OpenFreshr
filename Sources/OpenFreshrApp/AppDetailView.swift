import SwiftUI
import OpenFreshrCore

/// The detail pane for one selected app: identity, every detected source, the
/// adoption verdict and — when eligible — the button that opens the confirmation
/// sheet.
struct AppDetailView: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport

    @State private var showingAdoptionSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                sourcesSection
                Divider()
                verdictSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(report.app.displayName)
        .sheet(isPresented: $showingAdoptionSheet) {
            AdoptionSheet(report: report)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(report.app.displayName)
                .font(.largeTitle.bold())
            if let identifier = report.app.bundleIdentifier {
                Text(identifier)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
                LabeledContent("Kurzversion", value: report.app.shortVersion ?? "—")
                LabeledContent("Build", value: report.app.bundleVersion ?? "—")
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quellen")
                .font(.headline)

            if report.sources.isEmpty {
                Text("Keine Update-Quelle erkannt.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedSources, id: \.label) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.isManaging ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(source.isManaging ? .green : .secondary)
                        Text(source.label)
                        Spacer()
                        if source.isManaging {
                            Text("verwaltet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adoption")
                .font(.headline)

            switch report.eligibility {
            case let .eligible(token):
                Label("Adoptierbar als „\(token)“", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let prediction = report.predictedOutcome {
                    Text(prediction.explanation)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showingAdoptionSheet = true
                } label: {
                    Label("Mit Homebrew übernehmen …", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.homebrewAvailable || viewModel.adoptionInFlight.contains(report.app.bundlePath))

                if !viewModel.homebrewAvailable {
                    Text("Homebrew ist nicht verfügbar — Adoption ist deaktiviert, der Scan funktioniert weiterhin.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            case let .ineligible(reason):
                Label(reason.explanation, systemImage: "nosign")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortedSources: [AppSource] {
        report.sources.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
