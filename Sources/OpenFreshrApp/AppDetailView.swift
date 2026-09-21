import SwiftUI
import OpenFreshrCore

/// The detail pane for one selected app: identity, every detected source, the
/// per-source update state with a single-app update action, the adoption verdict
/// and — when eligible — the button that opens the confirmation sheet.
struct AppDetailView: View {

    @Environment(AppViewModel.self) private var viewModel
    let report: AppReport

    @State private var showingAdoptionSheet = false
    /// The user's explicit, per-view opt-in to a detected team-ID change. Reset
    /// whenever the selected app changes so consent never carries across apps.
    @State private var acknowledgeTeamChange = false

    private var update: AppUpdateReport? { viewModel.updateReport(for: report) }

    /// The cached trust picture for this app, if it has been evaluated yet.
    private var trust: TrustEvaluation? { viewModel.trustEvaluation(for: report.app) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                sourcesSection
                Divider()
                trustSection
                Divider()
                updatesSection
                Divider()
                verdictSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(report.app.displayName)
        .task(id: report.app.bundlePath) {
            acknowledgeTeamChange = false
            await viewModel.evaluateTrust(for: report.app)
        }
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
                LabeledContent("Short Version", value: report.app.shortVersion ?? "—")
                LabeledContent("Build", value: report.app.bundleVersion ?? "—")
                if let available = update?.primarySource?.state.availableVersion {
                    LabeledContent("Available", value: available)
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .padding(.top, 4)
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources")
                .font(.headline)

            if report.sources.isEmpty {
                Text("No update source detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedSources, id: \.label) { source in
                    HStack(spacing: 8) {
                        Image(systemName: source.isManaging ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(source.isManaging ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(source.label)
                        Spacer()
                        if source.isManaging {
                            Text("managed")
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
                    Text("No update source detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedUpdateSources) { source in
                        UpdateSourceRow(source: source)
                    }
                }

                if update.isSelfUpdating {
                    Label(
                        "This app updates itself. OpenFreshr only triggers it on explicit request, to avoid competing updaters.",
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
                    Text("Checking for updates …").foregroundStyle(.secondary)
                }
            } else {
                Text("Not checked for updates yet.")
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
                        "This app is not managed by Homebrew yet. OpenFreshr adopts it first (install --cask --adopt) and then updates it (reinstall --cask) — two steps, one action. If the adoption fails, the second step is not run.",
                        systemImage: "square.and.arrow.down.on.square"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if source.state.isMajor {
                    Label(
                        "Major upgrade — the first version component changes. Please confirm deliberately.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if source.isReceiptDrift {
                    Label(
                        "Homebrew already lists this app as up to date, but an older version is on disk. A normal upgrade would have no effect, so the app is reinstalled instead of updated.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let block = trustHardBlock {
                    trustHardBlockNotice(block)
                } else if let change = trust?.pendingTeamChange {
                    teamChangeWarning(change, update: update, source: source)
                } else {
                    Button {
                        Task { await viewModel.update(update, source: source) }
                    } label: {
                        Label(actionLabel(for: update, source: source), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(source.state.isMajor ? .orange : .accentColor)
                    .disabled(isInFlight)
                }
            }
        } else if let blocked = update.adoptionBlockedSource {
            adoptionRequiredNotice(for: blocked)
        }
    }

    /// A detected update whose only Homebrew path — taking the app over first — is
    /// **predicted to abort** (a non-auto-updating cask whose installed version
    /// differs; the Amazon Photos case). There is no honest one-click action, so
    /// instead of an "Update" button that could only fail, state plainly
    /// why and point the user at the vendor. Predicted up front so this is shown
    /// *before* any failed attempt.
    @ViewBuilder
    private func adoptionRequiredNotice(for source: SourceUpdate) -> some View {
        Label(
            source.actionBlocker?.explanation
                ?? String(localized: "This app cannot be adopted and updated automatically — please update via the vendor."),
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
            return String(localized: "Update via OpenFreshr anyway")
        }
        return source.state.isMajor ? String(localized: "Perform Major Upgrade") : String(localized: "Update")
    }

    /// A **secondary**, optional take-over: adopting an app into Homebrew even
    /// when no update is pending. This is no longer a prerequisite for updates —
    /// an app with an update shows a single "Aktualisieren" button that performs
    /// the take-over itself. This section only offers the standalone convenience.
    private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adoption by Homebrew")
                .font(.headline)

            switch report.eligibility {
            case let .eligible(token):
                Label("Adoptable as “\(token)”", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let prediction = report.predictedOutcome {
                    Text(prediction.explanation)
                        .foregroundStyle(.secondary)
                }
                Text("Optional — only needed if Homebrew should manage this app going forward. A pending update does not require a separate adoption.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingAdoptionSheet = true
                } label: {
                    Label("Adopt with Homebrew …", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.homebrewAvailable || viewModel.adoptionInFlight.contains(report.app.bundlePath))

                if !viewModel.homebrewAvailable {
                    Text("Homebrew is not available — adoption is disabled, scanning still works.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            case let .ineligible(reason):
                Label(reason.explanation, systemImage: "nosign")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Trust (phase 4)

    /// The trust section: signature verdict, Gatekeeper verdict, the currently
    /// signing team ID, the stored baseline, and the honest trust-on-first-use
    /// limitation. Read-only; the enforcement decision lives in the core gate.
    @ViewBuilder
    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trust & Signature")
                .font(.headline)

            if let trust {
                let signature = signatureLabel(trust.signature.verification)
                LabeledContent("Signature") { Text(signature.text).foregroundStyle(signature.color) }
                let gatekeeper = gatekeeperLabel(trust.signature.gatekeeper)
                LabeledContent("Gatekeeper") { Text(gatekeeper.text).foregroundStyle(gatekeeper.color) }
                LabeledContent("Signing Team ID") {
                    Text(trust.signature.teamIdentifier ?? String(localized: "not readable"))
                        .textSelection(.enabled)
                        .foregroundStyle(trust.signature.teamIdentifier == nil ? .secondary : .primary)
                }

                if let baseline = trust.baseline {
                    LabeledContent("Trusted Team ID") {
                        Text(baseline.teamIdentifier).textSelection(.enabled)
                    }
                    Text(baselineOriginText(baseline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No trust baseline stored yet. The next update records the currently signing team ID as the initial trust (trust-on-first-use).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("A deliberately named limit: if the first observed installation was already tampered with, exactly that state is taken as the initial trust. That is not verified safety, but a starting point against which later changes stand out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if trust.signature.wasDegradedByMissingTool {
                    Label("A check could not be run (tool missing). OpenFreshr therefore does not block across the board, but does not claim verified safety either.",
                        systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking signature and Gatekeeper …").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The hard (non-opt-in) trust block for this app, if any: an unsigned or
    /// invalid bundle, a Gatekeeper rejection, or an unreadable identity. A team-ID
    /// change is deliberately *not* here — that path offers a conscious opt-in.
    private var trustHardBlock: TrustBlock? {
        guard let trust else { return nil }
        switch trust.status {
        case .blockedUnsigned: return .unsigned
        case let .blockedSignatureInvalid(message): return .signatureInvalid(message)
        case let .blockedGatekeeperRejected(message): return .gatekeeperRejected(message)
        case .identityUnreadable: return .identityUnreadable
        default: return nil
        }
    }

    /// A hard stop: no opt-in, because there is nothing to consent *to* — the
    /// bundle cannot be shown to be the genuine, unmodified app.
    @ViewBuilder
    private func trustHardBlockNotice(_ block: TrustBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Replacement blocked", systemImage: "xmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(block.explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text("OpenFreshr does not replace this app automatically. Please check the origin of the app manually before you continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A prominent, non-dismissible-by-accident warning: old and new team ID, what
    /// a change may mean in both directions, a **separate** consent toggle, and a
    /// distinct red action that is disabled until the user consents.
    @ViewBuilder
    private func teamChangeWarning(
        _ change: TeamIdentifierChange,
        update: AppUpdateReport,
        source: SourceUpdate
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Team ID change detected", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text("This app is now signed by a different Apple team ID than at the last trusted observation. OpenFreshr therefore does not update it casually.")
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Previously trusted", value: change.previousTeamIdentifier)
            LabeledContent("Now signed by", value: change.newTeamIdentifier)

            Text("A change can mean a legitimate takeover by the vendor (new signing certificate, company acquisition) — or a takeover of the update channel by third parties. Both look the same here. Only agree if you have understood the change.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("I have checked the team ID change and deliberately agree to the replacement.",
                   isOn: $acknowledgeTeamChange)
                .toggleStyle(.checkbox)

            Button {
                Task { await viewModel.update(update, source: source, acknowledgeTeamChange: true) }
            } label: {
                Label("Replace anyway", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isInFlight || !acknowledgeTeamChange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func baselineOriginText(_ record: TrustRecord) -> String {
        let base: String
        switch record.origin {
        case .firstUse:
            base = String(localized: "Stored as the initial trust at the first observation.")
        case .userConfirmedChange:
            base = String(localized: "Last updated by a team ID change you deliberately confirmed.")
        }
        if record.confirmedChanges.isEmpty { return base }
        let count = record.confirmedChanges.count
        return base + " " + String(localized: "Confirmed changes: \(count).")
    }

    private func signatureLabel(_ verification: SignatureVerification) -> (text: String, color: Color) {
        switch verification {
        case .verified: return (String(localized: "verified (codesign --strict)"), .green)
        case .unsigned: return (String(localized: "not signed"), .red)
        case let .invalid(message): return (String(localized: "invalid – \(message)"), .red)
        case .toolUnavailable: return (String(localized: "not checked (tool missing)"), .orange)
        }
    }

    private func gatekeeperLabel(_ assessment: GatekeeperAssessment) -> (text: String, color: Color) {
        switch assessment {
        case .accepted: return (String(localized: "accepted (spctl execute)"), .green)
        case let .rejected(message): return (String(localized: "rejected – \(message)"), .red)
        case .toolUnavailable: return (String(localized: "not checked (tool missing)"), .orange)
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
                .accessibilityHidden(true)
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
            return String(localized: "current")
        case let .updateAvailable(available, isMajor):
            let arrow = isMajor ? String(localized: "Major → \(available)") : "→ \(available)"
            return source.adoptionWouldFail ? String(localized: "\(arrow) · via vendor") : arrow
        case let .unknown(reason):
            return reason.explanation
        }
    }
}
