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
                    "Keine Vertrauensentscheidungen gespeichert",
                    systemImage: "shield",
                    description: Text("Sobald OpenFreshr eine App zum ersten Mal ersetzt, wird deren Team ID "
                        + "hier als Ausgangsvertrauen abgelegt.")
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
                        Text("Zurücksetzen löscht das Ausgangsvertrauen. Die nächste Aktualisierung behandelt die "
                            + "App als neue Erstbeobachtung und legt die dann signierende Team ID neu ab — es ist "
                            + "kein stilles Weitervertrauen der alten Team ID.")
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
            Text("Vertrauensspeicher")
                .font(.title2.bold())
            Text("OpenFreshr merkt sich beim ersten Ersetzen die signierende Apple Team ID einer App als "
                + "Ausgangsvertrauen (Trust-on-first-use). War die erste Installation bereits manipuliert, wird "
                + "dieser Zustand übernommen — das ist eine bewusste Grenze, keine geprüfte Unbedenklichkeit. "
                + "Ein späterer Team-ID-Wechsel wird erkannt und erfordert Ihre ausdrückliche Zustimmung.")
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
                Label("Alle zurücksetzen", systemImage: "trash")
            }
            .disabled(records.isEmpty)
            .confirmationDialog(
                "Alle gespeicherten Vertrauensentscheidungen löschen?",
                isPresented: $confirmingResetAll,
                titleVisibility: .visible
            ) {
                Button("Alle zurücksetzen", role: .destructive) {
                    viewModel.resetAllTrust()
                    reload()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Jede App wird bei ihrer nächsten Aktualisierung wieder als Erstbeobachtung behandelt.")
            }

            Spacer()

            Button("Fertig") { dismiss() }
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
                Button("Zurücksetzen", role: .destructive, action: onReset)
                    .buttonStyle(.borderless)
            }

            LabeledContent("Vertraute Team ID") {
                Text(record.teamIdentifier).textSelection(.enabled)
            }
            LabeledContent("Herkunft", value: originText)
            LabeledContent("Zuletzt aktualisiert", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))

            if !record.confirmedChanges.isEmpty {
                Text("Bestätigte Team-ID-Wechsel")
                    .font(.caption.bold())
                    .padding(.top, 2)
                ForEach(Array(record.confirmedChanges.enumerated()), id: \.offset) { _, change in
                    Text("\(change.previousTeamIdentifier) → \(change.newTeamIdentifier) "
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
        case .firstUse: return "Erstbeobachtung (Trust-on-first-use)"
        case .userConfirmedChange: return "Vom Nutzer bestätigter Team-ID-Wechsel"
        }
    }
}
