import SwiftUI
import OpenFreshrCore

/// The "Alle Updates" preview: a per-app, checkbox-driven confirmation modelled
/// on ``AdoptionSheet``.
///
/// It keeps two invariants of the phase-3 contract visible and structural:
///
/// * **Regular and major upgrades are separated.** They live in two sections with
///   two independent selections and two buttons; a major upgrade can never ride
///   along in the regular release (the core's ``UpdateRelease`` would refuse it
///   anyway, but the UI never even offers it).
/// * **Self-updating apps are opt-in.** They appear unchecked with a tag, so the
///   default batch never drives a second updater against them.
///
/// Every row restates the exact command that would run, the same string the
/// coordinator executes — preview and execution can never drift.
struct UpdateSheet: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRegular: Set<String> = []
    @State private var selectedMajor: Set<String> = []
    @State private var didInitializeSelection = false

    private var regularItems: [UpdateItem] { viewModel.allUpdateItems.filter { !$0.isMajor } }
    private var majorItems: [UpdateItem] { viewModel.allUpdateItems.filter { $0.isMajor } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All Updates")
                .font(.title2.bold())

            if viewModel.allUpdateItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        regularSection
                        if !majorItems.isEmpty {
                            majorSection
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()

            HStack {
                if let message = viewModel.lastUpdateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: initializeSelectionIfNeeded)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No Executable Updates", systemImage: "checkmark.circle")
                .font(.headline)
            Text("No update that OpenFreshr can execute was detected for any app. Self-updating apps only appear here if a backend can drive them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Regular

    private var regularSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Regular Updates")
                    .font(.headline)
                Spacer()
                Button("Update Selected (\(selectedRegular.count))") {
                    Task { await runRegular() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRegular.isEmpty || anyInFlight)
            }

            if regularItems.isEmpty {
                Text("No regular updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(regularItems) { item in
                    UpdateItemRow(
                        item: item,
                        isSelfUpdating: isSelfUpdating(item),
                        isSelected: bindingForRegular(item)
                    )
                }
            }
        }
    }

    // MARK: - Major

    private var majorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Major Upgrades", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("The first version component changes. Confirm separately and deliberately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Perform Major Upgrades (\(selectedMajor.count))") {
                    Task { await runMajor() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(selectedMajor.isEmpty || anyInFlight)
            }

            ForEach(majorItems) { item in
                UpdateItemRow(
                    item: item,
                    isSelfUpdating: isSelfUpdating(item),
                    isSelected: bindingForMajor(item)
                )
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func runRegular() async {
        let items = regularItems.filter { selectedRegular.contains($0.id) }
        await viewModel.performUpdates(items)
    }

    private func runMajor() async {
        let items = majorItems.filter { selectedMajor.contains($0.id) }
        await viewModel.performUpdates(items)
    }

    private var anyInFlight: Bool { !viewModel.updateInFlight.isEmpty }

    private func isSelfUpdating(_ item: UpdateItem) -> Bool {
        viewModel.updateReports[item.app.bundlePath]?.isSelfUpdating ?? false
    }

    /// Pre-check the regular updates OpenFreshr may drive by default; leave major
    /// upgrades and self-updating apps unchecked so both stay opt-in.
    private func initializeSelectionIfNeeded() {
        guard !didInitializeSelection else { return }
        didInitializeSelection = true
        selectedRegular = Set(
            regularItems
                .filter { viewModel.isDefaultSelectable($0) }
                .map(\.id)
        )
    }

    private func bindingForRegular(_ item: UpdateItem) -> Binding<Bool> {
        Binding(
            get: { selectedRegular.contains(item.id) },
            set: { isOn in
                if isOn { selectedRegular.insert(item.id) } else { selectedRegular.remove(item.id) }
            }
        )
    }

    private func bindingForMajor(_ item: UpdateItem) -> Binding<Bool> {
        Binding(
            get: { selectedMajor.contains(item.id) },
            set: { isOn in
                if isOn { selectedMajor.insert(item.id) } else { selectedMajor.remove(item.id) }
            }
        )
    }
}

/// One selectable update row: checkbox, identity, target version, backend and the
/// exact command, plus live progress and the last outcome.
private struct UpdateItemRow: View {

    @Environment(AppViewModel.self) private var viewModel
    let item: UpdateItem
    let isSelfUpdating: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $isSelected) { Text("Select for update") }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(inFlight)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.app.displayName)
                        .font(.body.weight(.medium))
                    Text("→ \(item.targetVersion)")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(item.backend.label)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                if isSelfUpdating {
                    Label("Self-updating — opt-in", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(item.commandPlan.enumerated()), id: \.offset) { _, command in
                    Text(command.displayString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }

                if item.homebrewStrategy == .adoptThenReinstall {
                    Label(
                        "Not managed by Homebrew — adopted first, then updated (two steps, one action).",
                        systemImage: "square.and.arrow.down.on.square"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if inFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("running …").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let outcome = viewModel.updateOutcomes[item.app.bundlePath] {
                    Text(outcome)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var inFlight: Bool {
        viewModel.updateInFlight.contains(item.app.bundlePath)
    }
}
