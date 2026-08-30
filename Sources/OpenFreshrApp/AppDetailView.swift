import SwiftUI
import OpenFreshrCore

/// The detail pane for one selected app: identity, every detected source, the
/// per-source update state with a single-app update action, the adoption verdict
/// and — when eligible — the button that opens the confirmation sheet.
struct AppDetailView: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport

    @State private var showingAdoptionSheet = false

    private var update: AppUpdateReport? { viewModel.updateReport(for: report) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                sourcesSection
                Divider()
                updatesSection
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
                if let available = update?.primarySource?.state.availableVersion {
                    LabeledContent("Verfügbar", value: available)
                        .foregroundStyle(.orange)
                }
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

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates")
                .font(.headline)

            if let update {
                if update.sources.isEmpty {
                    Text("Keine Update-Quelle erkannt.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedUpdateSources) { source in
                        UpdateSourceRow(source: source)
                    }
                }

                if update.isSelfUpdating {
                    Label(
                        "Diese App aktualisiert sich selbst. OpenFreshr stösst sie nur auf ausdrückliche Anforderung an, "
                            + "um konkurrierende Updater zu vermeiden.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                updateAction(for: update)

                if let outcome = viewModel.updateOutcomes[report.app.bundlePath] {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isCheckingUpdates {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Prüfe auf Updates …").foregroundStyle(.secondary)
                }
            } else {
                Text("Noch nicht auf Updates geprüft.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func updateAction(for update: AppUpdateReport) -> some View {
        if let source = update.sources.first(where: { $0.isDrivable }) {
            VStack(alignment: .leading, spacing: 8) {
                // Show *every* command that will actually run, in order. For an
                // adoptable-but-unmanaged app that is both steps (adopt, then
                // reinstall) — one user action, fully transparent.
                ForEach(Array(source.commandPlan.enumerated()), id: \.offset) { _, command in
                    Text(command.displayString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                if source.homebrewStrategy == .adoptThenReinstall {
                    Label(
                        "Diese App wird noch nicht von Homebrew verwaltet. OpenFreshr übernimmt sie zuerst "
                            + "(install --cask --adopt) und aktualisiert sie dann (reinstall --cask) — zwei Schritte, "
                            + "eine Aktion. Schlägt die Übernahme fehl, wird der zweite Schritt nicht ausgeführt.",
                        systemImage: "square.and.arrow.down.on.square"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if source.state.isMajor {
                    Label(
                        "Major-Upgrade — die erste Versionskomponente ändert sich. Bitte bewusst bestätigen.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if source.isReceiptDrift {
                    Label(
                        "Homebrew führt diese App bereits als aktuell, auf der Platte liegt aber eine ältere Version. "
                            + "Ein normales Upgrade bliebe wirkungslos, deshalb wird die App neu installiert statt aktualisiert.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await viewModel.update(update, source: source) }
                } label: {
                    Label(actionLabel(for: update, source: source), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(source.state.isMajor ? .orange : .accentColor)
                .disabled(isInFlight)
            }
        } else if let blocked = update.adoptionBlockedSource {
            adoptionRequiredNotice(for: blocked)
        }
    }

    /// A detected update whose only Homebrew path — taking the app over first — is
    /// **predicted to abort** (a non-auto-updating cask whose installed version
    /// differs; the Amazon Photos case). There is no honest one-click action, so
    /// instead of an "Aktualisieren" button that could only fail, state plainly
    /// why and point the user at the vendor. Predicted up front so this is shown
    /// *before* any failed attempt.
    @ViewBuilder
    private func adoptionRequiredNotice(for source: SourceUpdate) -> some View {
        Label(
            source.actionBlocker?.explanation
                ?? "Diese App kann nicht automatisch übernommen und aktualisiert werden — bitte über den Hersteller aktualisieren.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actionLabel(for update: AppUpdateReport, source: SourceUpdate) -> String {
        // A self-updating app driven by anything other than MAU is an explicit
        // opt-in; name it as such so the user knows they are overriding a default.
        if update.isSelfUpdating && source.backend != .microsoftAutoUpdate {
            return "Trotzdem über OpenFreshr aktualisieren"
        }
        return source.state.isMajor ? "Major-Upgrade durchführen" : "Aktualisieren"
    }

    /// A **secondary**, optional take-over: adopting an app into Homebrew even
    /// when no update is pending. This is no longer a prerequisite for updates —
    /// an app with an update shows a single "Aktualisieren" button that performs
    /// the take-over itself. This section only offers the standalone convenience.
    private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Übernahme durch Homebrew")
                .font(.headline)

            switch report.eligibility {
            case let .eligible(token):
                Label("Adoptierbar als „\(token)“", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let prediction = report.predictedOutcome {
                    Text(prediction.explanation)
                        .foregroundStyle(.secondary)
                }
                Text("Optional — nur nötig, wenn Homebrew diese App künftig mitverwalten soll. "
                    + "Für ein anstehendes Update ist keine separate Übernahme erforderlich.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingAdoptionSheet = true
                } label: {
                    Label("Mit Homebrew übernehmen …", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.homebrewAvailable || viewModel.adoptionInFlight.contains(report.app.bundlePath))

                if !viewModel.homebrewAvailable {
                    Text("Homebrew ist nicht verfügbar — Übernahme ist deaktiviert, der Scan funktioniert weiterhin.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            case let .ineligible(reason):
                Label(reason.explanation, systemImage: "nosign")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isInFlight: Bool {
        viewModel.updateInFlight.contains(report.app.bundlePath)
    }

    private var sortedSources: [AppSource] {
        report.sources.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var sortedUpdateSources: [SourceUpdate] {
        (update?.sources ?? []).sorted { $0.kind.label.localizedCaseInsensitiveCompare($1.kind.label) == .orderedAscending }
    }
}

/// One line describing a single source's determined update state.
private struct UpdateSourceRow: View {

    let source: SourceUpdate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(source.kind.label)
            Spacer()
            Text(stateText)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch source.state {
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable(_, let isMajor): return isMajor ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        if source.adoptionWouldFail { return .secondary }
        switch source.state {
        case .upToDate: return .green
        case .updateAvailable(_, let isMajor): return isMajor ? .orange : .accentColor
        case .unknown: return .secondary
        }
    }

    private var stateText: String {
        switch source.state {
        case .upToDate:
            return "aktuell"
        case let .updateAvailable(available, isMajor):
            let arrow = isMajor ? "Major → \(available)" : "→ \(available)"
            return source.adoptionWouldFail ? "\(arrow) · über Hersteller" : arrow
        case let .unknown(reason):
            return reason.explanation
        }
    }
}
