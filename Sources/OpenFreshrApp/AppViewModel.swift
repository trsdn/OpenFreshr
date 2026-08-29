import Foundation
import Observation
import OpenFreshrCore

/// The single source of truth for the SwiftUI shell.
///
/// It owns a ``AdoptionCoordinator`` wired to the *real* platform
/// implementations and exposes an async, main-actor-friendly surface: the
/// blocking scan and adopt calls — and the one-off 2.6 MB catalog load — are
/// pushed off the main actor and their results published back. Construction is
/// cheap: it starts over an empty catalog so the window draws immediately, then
/// swaps in the real catalog once it has been parsed off the main actor. All the
/// safety logic lives in the core; this class only sequences it and holds view
/// state.
@MainActor
@Observable
public final class AppViewModel {

    /// Every scanned app with its matches, sources and eligibility.
    public private(set) var reports: [AppReport] = []

    /// `true` while a scan is running, so the UI can show progress.
    public private(set) var isScanning = false

    /// Whether a usable `brew` was found. `false` degrades the UI (adoption
    /// disabled) but never blocks scanning.
    public private(set) var homebrewAvailable = false

    /// Age of the loaded cask catalog, for a "catalog is N old" hint.
    public private(set) var catalogAge: TimeInterval?

    /// The row currently selected in the list.
    public var selectedReportID: AppReport.ID?

    /// Tokens/apps whose adoption is in flight, keyed by bundle path.
    public private(set) var adoptionInFlight: Set<String> = []

    /// The most recent human-facing adoption outcome, for a status line.
    public private(set) var lastAdoptionMessage: String?

    /// Rebuilt once the catalog finishes loading; starts over an empty catalog so
    /// the first frame is not blocked on parsing the snapshot.
    private var coordinator: AdoptionCoordinator
    private let backend: any PackageBackend
    private let scanner: InventoryScanner
    private let scanDirectories: [String]

    /// The one-shot, off-main catalog load. ``scan()`` awaits it so the first scan
    /// never classifies against the empty placeholder catalog; by the time it
    /// completes the loaded catalog has already been published on the main actor.
    private var catalogLoad: Task<Void, Never>?

    public init() {
        let fileSystem = SystemFileSystem()
        let processRunner = SystemProcessRunner()
        let backend = HomebrewBackend(processRunner: processRunner, fileSystem: fileSystem)
        let scanner = InventoryScanner(fileSystem: fileSystem)

        self.backend = backend
        self.scanner = scanner
        self.scanDirectories = InventoryScanner.defaultScanDirectories

        // Start over an empty catalog so `init` does no heavy work on the main
        // actor and the window can draw its first frame at once. The 2.6 MB
        // snapshot (~5 000 casks, ~91 000 regex evaluations through
        // CaskCatalogIngestion) is parsed off the main actor and swapped in below.
        self.coordinator = AdoptionCoordinator(
            scanner: scanner,
            backend: backend,
            catalog: CaskCatalog(casks: [], fetchedAt: .distantPast),
            scanDirectories: InventoryScanner.defaultScanDirectories
        )

        self.catalogLoad = Task { [weak self] in
            let catalog = await Task.detached(priority: .userInitiated) {
                Self.loadCatalog()
            }.value
            self?.publishCatalog(catalog)
        }
    }

    /// Swap the freshly loaded catalog into a rebuilt coordinator on the main
    /// actor. ``AdoptionCoordinator`` is a value type, so replacing it is all it
    /// takes for the next scan to see the real catalog.
    private func publishCatalog(_ catalog: CaskCatalog) {
        self.catalogAge = catalog.age()
        self.coordinator = AdoptionCoordinator(
            scanner: scanner,
            backend: backend,
            catalog: catalog,
            scanDirectories: scanDirectories
        )
    }

    /// The currently selected report, if any.
    public var selectedReport: AppReport? {
        guard let selectedReportID else { return nil }
        return reports.first { $0.id == selectedReportID }
    }

    /// Run a full inventory scan and classification off the main actor.
    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // Gate the first scan on the catalog load: awaiting the one-shot task
        // guarantees we never classify against the empty placeholder. Later scans
        // find it already finished and continue without delay.
        await catalogLoad?.value

        let coordinator = self.coordinator
        let backend = self.backend
        let reports = await Task.detached { coordinator.makeReports() }.value
        let available = await Task.detached { backend.isAvailable() }.value

        self.reports = reports.sorted { $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending }
        self.homebrewAvailable = available
    }

    /// Attempt to adopt `app`, then refresh the affected report from the
    /// coordinator's rescan-confirmed result.
    public func adopt(_ app: InstalledApp) async {
        guard !adoptionInFlight.contains(app.bundlePath) else { return }
        adoptionInFlight.insert(app.bundlePath)
        defer { adoptionInFlight.remove(app.bundlePath) }

        let coordinator = self.coordinator
        let result = await Task.detached { coordinator.adopt(app) }.value

        switch result {
        case let .adopted(report):
            lastAdoptionMessage = "\(app.displayName) wird jetzt von Homebrew verwaltet."
            // The coordinator already rescanned and re-classified this app to
            // confirm the adoption; reuse that verified report instead of
            // triggering a second full inventory scan.
            replace(report)
        case let .hardFailedWithCaskError(message):
            lastAdoptionMessage = "Adoption abgebrochen (CaskError): \(message)"
        case .notConfirmedByRescan:
            lastAdoptionMessage = "\(app.displayName): Homebrew meldete Erfolg, der erneute Scan bestätigt ihn aber nicht."
        case let .failed(reason):
            lastAdoptionMessage = "\(app.displayName): \(reason.explanation)"
        case let .notEligible(reason):
            lastAdoptionMessage = "\(app.displayName) ist nicht adoptierbar: \(reason.explanation)"
        }
    }

    private func replace(_ report: AppReport) {
        if let index = reports.firstIndex(where: { $0.id == report.id }) {
            reports[index] = report
        }
    }

    /// Load the cask catalog from the snapshot bundled with the app, falling back
    /// to an empty catalog only if that resource is somehow missing.
    ///
    /// Phase 1 loads **only** the bundled snapshot. It is deliberately *not*
    /// backed by an on-disk cache: there is no producer for one in phase 1, so a
    /// `~/Library/Application Support/OpenFreshr/casks.json` would be pure attack
    /// surface — any process with the user's write access could hand-craft
    /// `primaryBundleIdentifiers`/`autoUpdates`/`artifacts` and defeat every
    /// corroboration and veto check. The snapshot is the real Homebrew cask API
    /// shape and is ingested by the production ``CaskCatalogIngestion``, so the
    /// app matches real apps out of the box with no network and no Homebrew.
    ///
    /// - Important: When a later phase adds live fetching plus a refresh cache, it
    ///   **must** ingest that data through ``CaskCatalogIngestion`` (the *API*
    ///   form), exactly as the snapshot is here — never by decoding external bytes
    ///   straight into the internal ``Cask`` `Codable` form. Only ingestion
    ///   *recovers* identity from stanzas under our own rules; decoding the
    ///   internal form would let untrusted input set internal safety fields
    ///   (`primaryBundleIdentifiers`, `autoUpdates`, …) directly.
    private nonisolated static func loadCatalog() -> CaskCatalog {
        if let catalog = loadBundledSnapshot() {
            return catalog
        }
        return CaskCatalog(casks: [], fetchedAt: .distantPast)
    }

    /// Ingest the catalog snapshot shipped as an app resource, if present.
    private nonisolated static func loadBundledSnapshot() -> CaskCatalog? {
        guard let url = Bundle.main.url(forResource: "casks-snapshot", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        // Date the snapshot by its bundled file so the "catalog is N old" hint is
        // honest about how stale the shipped data is.
        let fetchedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            ?? .distantPast
        return try? CaskCatalogIngestion.decodeCatalog(fromAPIData: data, fetchedAt: fetchedAt)
    }
}
