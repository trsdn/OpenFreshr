import SwiftUI
import OpenFreshrCore

/// A modal confirmation for a single fresh install.
///
/// Like ``AdoptionSheet`` it restates the **exact** command that will run
/// (`brew install --cask -- <token>`), warns when the cask installs via a
/// privileged installer rather than dropping an app in place, and only then lets
/// the user proceed. The install, the rescan and the confirmation are the
/// coordinator's; this sheet only gathers consent.
struct InstallSheet: View {

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    let result: CatalogSearchResult
    let model: CatalogViewModel

    private var cask: Cask { result.cask }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("App installieren")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.displayName) wird über Homebrew neu installiert.")
                if let command = model.installCommandPreview(for: cask) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Label(
                        "Ohne verfügbares Homebrew kann kein Installationsbefehl gebildet werden.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            if result.isInstallerOnly {
                Label(
                    "Dieser Cask liefert kein App-Bundle, sondern startet einen pkg-/Installer "
                        + "mit Rechteabfrage (Administratorkennwort). Der Erfolg wird über den "
                        + "Homebrew-Eintrag bestätigt, nicht über eine gefundene App.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            if result.isInstalled {
                Label(
                    "Diese App ist bereits vorhanden. Eine erneute Installation ist normalerweise "
                        + "nicht nötig.",
                    systemImage: "checkmark.seal"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            Label(
                "Nach der Installation wird ein Scan ausgeführt. Erfolg wird nur gemeldet, wenn die "
                    + "App danach tatsächlich gefunden wird.",
                systemImage: "magnifyingglass"
            )
            .foregroundStyle(.secondary)
            .font(.callout)

            if isInFlight {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installation läuft …").foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Installieren") {
                    Task {
                        await model.install(cask)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!appViewModel.homebrewAvailable || isInFlight)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var isInFlight: Bool {
        model.installInFlight.contains(cask.token)
    }
}
