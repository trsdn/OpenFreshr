import Foundation
import Observation
import OpenFreshrCore

/// The human-facing outcome of a single catalog install, mapped from the core's
/// ``InstallResult`` for the row and detail pane. Success is only ever set from a
/// result the coordinator confirmed by rescan.
public struct CatalogInstallOutcome: Sendable, Equatable {
    public enum State: Sendable { case success, info, failure }
    public var state: State
    public var text: String
}

/// Drives the catalog pane: a prepared, off-main search index over the whole
/// cask catalog and the confirmed install flow.
///
/// It deliberately owns its **own** real platform stack (a `HomebrewBackend`, an
/// `InventoryScanner`, a `TrustGate`) and an ``InstallCoordinator`` built over
/// them, so the flagship install path lives in the core and stays testable while
/// this class only sequences it and holds view state. The heavy work — building
/// the ~7700-entry index and running `brew install` — is pushed off the main
/// actor; only the results are published back.
///
/// It reads the loaded catalog, popularity analytics and the installed-app
/// context from ``AppViewModel`` (via ``configure(catalog:analytics:installedBundleNames:recognizedTokens:)``)
/// rather than re-deriving them, and asks the app to rescan after a confirmed
/// install so the new app shows up under "Installiert" — and so the catalog
/// re-marks it as already installed.
@MainActor
@Observable
public final class CatalogViewModel {

    /// The live search text. The view observes it and calls ``search()`` on change.
    public var query: String = ""

    /// The (display-capped) ranked results for the current query.
    public private(set) var results: [CatalogSearchResult] = []

    /// How many casks matched the current query before the display cap, so the UI
    /// can honestly say "250 von 1234".
    public private(set) var matchCount = 0

    /// How many casks the index can search — the "durchsuchbar" headline.
    public private(set) var indexCount = 0

    /// `true` while the index is being (re)built off the main actor.
    public private(set) var isIndexing = false

    /// The row selected in the catalog list.
    public var selectedTokenID: CatalogSearchResult.ID?

    /// Tokens whose install is in flight, so rows show progress and disable their
    /// button.
    public private(set) var installInFlight: Set<String> = []

    /// Per-token last install outcome, for the row badge and the detail pane.
    public private(set) var installOutcomes: [String: CatalogInstallOutcome] = [:]

    /// Called after a *confirmed* install so the app can rescan; the rescan makes
    /// the freshly installed app appear under "Installiert" and re-marks it here.
    public var onInstalled: (() async -> Void)?

    /// The most a `List` renders at once; the full catalog is searchable, but
    /// showing every one of thousands of rows for an empty query helps no one.
    private static let displayLimit = 250

    private let backend: HomebrewBackend
    private let scanner: InventoryScanner
    private let scanDirectories: [String]
    private let coordinator: InstallCoordinator

    /// The prepared index. Rebuilt only when its inputs actually change, never on
    /// a keystroke.
    private var index: CatalogSearchIndex?

    /// A signature of the inputs the current index was built from, so repeated
    /// ``configure`` calls with unchanged data do not rebuild it.
    private var indexSignature: Int?

    public init() {
        let fileSystem = SystemFileSystem()
        let processRunner = SystemProcessRunner()
        let backend = HomebrewBackend(processRunner: processRunner, fileSystem: fileSystem)
        let scanner = InventoryScanner(fileSystem: fileSystem)
        let trustGate = TrustGate(
            inspector: SystemCodeSignatureInspector(processRunner: processRunner, fileSystem: fileSystem),
            store: JSONFileTrustStore()
        )

        self.backend = backend
        self.scanner = scanner
        self.scanDirectories = InventoryScanner.defaultScanDirectories
        self.coordinator = InstallCoordinator(
            scanner: scanner,
            backend: backend,
            scanDirectories: InventoryScanner.defaultScanDirectories,
            trustGate: trustGate
        )
    }

    /// Feed the catalog view its data. Rebuilds the search index off the main
    /// actor when — and only when — the catalog, analytics or installed context
    /// changed, then refreshes the visible results. Safe to call on every data
    /// change; unchanged inputs are a no-op.
    public func configure(
        catalog: CaskCatalog,
        analytics: CaskInstallAnalytics?,
        installedBundleNames: Set<String>,
        recognizedTokens: Set<String>
    ) async {
        let signature = Self.signature(
            catalog: catalog,
            analytics: analytics,
            installedBundleNames: installedBundleNames,
            recognizedTokens: recognizedTokens
        )
        guard signature != indexSignature else { return }

        isIndexing = true
        let built = await Task.detached(priority: .userInitiated) {
            CatalogSearchIndex(
                catalog: catalog,
                analytics: analytics,
                installedBundleNames: installedBundleNames,
                recognizedTokens: recognizedTokens
            )
        }.value

        self.index = built
        self.indexSignature = signature
        self.indexCount = built.count
        self.isIndexing = false
        search()
    }

    /// Run the current query against the prepared index. Synchronous because the
    /// index makes a query a cheap substring scan; the result list is capped for
    /// rendering while ``matchCount`` reports the true total.
    public func search() {
        guard let index else {
            results = []
            matchCount = 0
            return
        }
        let matched = index.search(query)
        matchCount = matched.count
        results = Array(matched.prefix(Self.displayLimit))

        // Keep the selection valid so the detail pane never dangles.
        if let selectedTokenID, !results.contains(where: { $0.id == selectedTokenID }) {
            self.selectedTokenID = results.first?.id
        } else if selectedTokenID == nil {
            self.selectedTokenID = results.first?.id
        }
    }

    /// The result currently selected, if any.
    public var selectedResult: CatalogSearchResult? {
        guard let selectedTokenID else { return nil }
        return results.first { $0.id == selectedTokenID }
    }

    /// The exact command an install would run, for the preview sheet. `nil` when
    /// Homebrew is absent or the token is invalid — the same guard the backend
    /// enforces before any launch.
    public func installCommandPreview(for cask: Cask) -> String? {
        backend.resolveInstallCommand(identifier: cask.token)?.displayString
    }

    /// Install `cask` through the coordinator (install → rescan → confirm), off
    /// the main actor. Records a per-token outcome and, on a confirmed install,
    /// asks the app to rescan. Failures stay isolated to this token and are
    /// retryable.
    public func install(_ cask: Cask) async {
        guard !installInFlight.contains(cask.token) else { return }
        installInFlight.insert(cask.token)
        installOutcomes[cask.token] = nil

        let coordinator = self.coordinator
        let result = await Task.detached(priority: .userInitiated) {
            coordinator.install(cask)
        }.value

        installInFlight.remove(cask.token)
        installOutcomes[cask.token] = Self.outcome(for: result, cask: cask)

        if result.didInstall {
            await onInstalled?()
        }
    }

    // MARK: - mapping

    private static func outcome(for result: InstallResult, cask: Cask) -> CatalogInstallOutcome {
        switch result {
        case .installed:
            return .init(state: .success, text: "Installiert und per Scan bestätigt.")
        case .installedInstaller:
            return .init(state: .success, text: "Installer ausgeführt; von Homebrew verwaltet.")
        case .alreadyInstalled:
            return .init(state: .info, text: "Bereits von Homebrew verwaltet – nichts zu tun.")
        case .notConfirmedByRescan:
            return .init(
                state: .failure,
                text: "Der Scan nach der Installation hat die App nicht gefunden. Bitte erneut versuchen."
            )
        case let .hardFailedWithCaskError(message):
            return .init(state: .failure, text: Self.trim(message))
        case let .failed(reason):
            return .init(state: .failure, text: Self.describe(reason))
        }
    }

    private static func describe(_ reason: BackendFailureReason) -> String {
        switch reason {
        case let .processFailed(exitCode, standardError):
            let detail = trim(standardError)
            return detail.isEmpty
                ? "Installation fehlgeschlagen (Code \(exitCode))."
                : detail
        case .homebrewUnavailable, .toolUnavailable, .launchFailed,
             .invalidCaskToken, .invalidIdentifier, .requiresAdoption:
            return reason.explanation
        }
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A cheap, order-independent signature of the index inputs. Catalog identity
    /// is its fetch time and size (a swap always changes one of them); the two
    /// sets and the analytics size complete the picture.
    private static func signature(
        catalog: CaskCatalog,
        analytics: CaskInstallAnalytics?,
        installedBundleNames: Set<String>,
        recognizedTokens: Set<String>
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(catalog.fetchedAt)
        hasher.combine(catalog.casks.count)
        hasher.combine(analytics?.count ?? 0)
        hasher.combine(installedBundleNames)
        hasher.combine(recognizedTokens)
        return hasher.finalize()
    }
}
