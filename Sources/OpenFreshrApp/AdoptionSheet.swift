import OpenFreshrCore
import SwiftUI

/// A modal confirmation for a single adoption.
///
/// It restates the exact command intent (`brew install --cask --adopt <token>`),
/// surfaces the predicted outcome — including the `CaskError` warning — and only
/// then lets the user proceed. The heavy lifting and the rescan-confirmation are
/// the coordinator's; this sheet just gathers consent and shows the result.
struct AdoptionSheet: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let report: AppReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Adopt App")
                .font(.title2.bold())

            if let token = report.eligibility.caskToken {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(report.app.displayName) will be managed by Homebrew from now on.")
                    Text(verbatim: "brew install --cask --adopt \(token)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                if let prediction = report.predictedOutcome {
                    Label(prediction.explanation, systemImage: iconName(for: prediction))
                        .foregroundStyle(color(for: prediction))
                        .font(.callout)
                }
            } else {
                Text("This app cannot be adopted.")
                    .foregroundStyle(.secondary)
            }

            // Unlike a Mac App Store receipt (which blocks adoption outright), a
            // Microsoft AutoUpdate app stays adoptable — but the user should know
            // a second updater will keep running, so warn explicitly here.
            if report.app.isMicrosoftAutoUpdateManaged {
                Label(
                    "This app is also managed by Microsoft AutoUpdate (MAU). After adoption, Homebrew and MAU update it in parallel.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            if isInFlight {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adopting …").foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adopt") {
                    Task {
                        await viewModel.adopt(report.app)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!report.eligibility.isEligible || !viewModel.homebrewAvailable || isInFlight)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var isInFlight: Bool {
        viewModel.adoptionInFlight.contains(report.app.bundlePath)
    }

    private func iconName(for prediction: AdoptionOutcomePrediction) -> String {
        switch prediction {
        case .succeedsUnconditionally, .succeeds: return "checkmark.circle"
        case .abortsWithCaskError: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for prediction: AdoptionOutcomePrediction) -> Color {
        switch prediction {
        case .succeedsUnconditionally, .succeeds: return .green
        case .abortsWithCaskError: return .orange
        case .unknown: return .secondary
        }
    }
}
