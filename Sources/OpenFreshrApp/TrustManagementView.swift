import SwiftUI
import OpenFreshrCore

/// The trust store, made visible and resettable.
///
/// It lists every stored trust decision — the team ID OpenFreshr treats as the
/// baseline for a bundle, where that baseline came from, and any team-ID changes
/// the user has consciously confirmed — and lets the user forget one or all of
/// them. It also states, plainly, the trust-on-first-use limitation so the store
/// is not mistaken for a guarantee.
struct TrustManagementView: View {

    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    /// A local copy so the list refreshes deterministically after a reset; the
    /// store itself is not an observable source.
    @State private var records: [TrustRecord] = []
    @State private var confirmingResetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if records.isEmpty {
                ContentUnavailableView(
                    "No Trust Decisions Stored",
                    systemImage: "shield",
                    description: Text("As soon as OpenFreshr replaces an app for the first time, its team ID is stored here as the initial trust.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(records) { record in
                            TrustRecordRow(record: record) {
                                viewModel.resetTrust(bundleIdentifier: record.bundleIdentifier)
                                reload()
                            }
                        }
                    } footer: {
                        Text("Resetting deletes the initial trust. The next update treats the app as a new first observation and stores the then-signing team ID anew — it is not a silent continued trust in the old team ID.")
                            .font(.caption)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: reload)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trust Store")
                .font(.title2.bold())
            Text("When it first replaces an app, OpenFreshr remembers the signing Apple team ID as the initial trust (trust-on-first-use). If the first installation was already tampered with, that state is adopted — this is a deliberate limit, not verified safety. A later team ID change is detected and requires your explicit consent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                confirmingResetAll = true
            } label: {
                Label("Reset All", systemImage: "trash")
            }
            .disabled(records.isEmpty)
            .confirmationDialog(
                "Delete all stored trust decisions?",
                isPresented: $confirmingResetAll,
                titleVisibility: .visible
            ) {
                Button("Reset All", role: .destructive) {
                    viewModel.resetAllTrust()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each app is treated as a first observation again at its next update.")
            }

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func reload() {
        records = viewModel.storedTrustRecords()
    }
}

/// One stored trust decision: identity, trusted team ID, provenance and any
/// confirmed team-ID changes, with a per-app reset.
private struct TrustRecordRow: View {

    let record: TrustRecord
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.bundleIdentifier)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
                Button("Reset", role: .destructive, action: onReset)
                    .buttonStyle(.borderless)
            }

            LabeledContent("Trusted Team ID") {
                Text(record.teamIdentifier).textSelection(.enabled)
            }
            LabeledContent("Origin", value: originText)
            LabeledContent("Last Updated", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))

            if !record.confirmedChanges.isEmpty {
                Text("Confirmed Team ID Changes")
                    .font(.caption.bold())
                    .padding(.top, 2)
                ForEach(Array(record.confirmedChanges.enumerated()), id: \.offset) { _, change in
                    Text(verbatim: "\(change.previousTeamIdentifier) → \(change.newTeamIdentifier) "
                        + "· \(change.confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var originText: String {
        switch record.origin {
        case .firstUse: return String(localized: "First observation (trust-on-first-use)")
        case .userConfirmedChange: return String(localized: "Team ID change confirmed by the user")
        }
    }
}
