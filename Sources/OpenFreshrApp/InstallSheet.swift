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
            Text("Install App")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.displayName) will be installed via Homebrew.")
                if let command = model.installCommandPreview(for: cask) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Label(
                        "Without Homebrew available, no install command can be built.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            if result.isInstallerOnly {
                Label(
                    "This cask does not provide an app bundle, but starts a pkg/installer with an authorization prompt (administrator password). Success is confirmed via the Homebrew entry, not via a found app.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            if result.isInstalled {
                Label(
                    "This app is already present. A reinstall is normally not necessary.",
                    systemImage: "checkmark.seal"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            Label(
                "A scan runs after the installation. Success is only reported if the app is actually found afterwards.",
                systemImage: "magnifyingglass"
            )
            .foregroundStyle(.secondary)
            .font(.callout)

            if isInFlight {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing …").foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
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
