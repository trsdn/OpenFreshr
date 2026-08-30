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

    /// Update reports keyed by bundle path, produced by the update coordinator.
    /// Empty until the first ``checkForUpdates()`` completes; the UI degrades to
    /// "not yet checked" rather than blocking on it.
    public private(set) var updateReports: [String: AppUpdateReport] = [:]

    /// `true` while update detection (scan + feeds + tools) is running.
    public private(set) var isCheckingUpdates = false

    /// Bundle paths whose update is in flight, so rows can show progress and
    /// disable their buttons.
    public private(set) var updateInFlight: Set<String> = []

    /// Per-app last update outcome message, keyed by bundle path.
    public private(set) var updateOutcomes: [String: String] = [:]

    /// The most recent human-facing update outcome, for the status line.
    public private(set) var lastUpdateMessage: String?

    /// The sidebar filter the user has selected.
    public var listFilter: AppListFilter = .all

    /// Rebuilt once the catalog finishes loading; starts over an empty catalog so
    /// the first frame is not blocked on parsing the snapshot.
    private var coordinator: AdoptionCoordinator
    private let backend: HomebrewBackend
    private let scanner: InventoryScanner
    private let scanDirectories: [String]

    /// The update-side coordinator, wired to the real platform implementations.
    /// Rebuilt alongside ``coordinator`` when the catalog loads. A value type, so
    /// swapping it is all the next update check needs to see the real catalog.
    private var updateCoordinator: UpdateCoordinator
    private let macAppStore: MacAppStoreBackend
    private let microsoftAutoUpdate: MicrosoftAutoUpdateBackend
    private let httpFetcher: any HTTPFetching

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

        // The auxiliary update backends and the (first, real) network fetcher.
        // These resolve their tools by absolute path and degrade to `unbekannt`
        // when a tool is absent, so constructing them is always safe.
        let macAppStore = MacAppStoreBackend(processRunner: processRunner, fileSystem: fileSystem)
        let microsoftAutoUpdate = MicrosoftAutoUpdateBackend(processRunner: processRunner, fileSystem: fileSystem)
        let httpFetcher = SystemHTTPFetcher()
        self.macAppStore = macAppStore
        self.microsoftAutoUpdate = microsoftAutoUpdate
        self.httpFetcher = httpFetcher

        // Start over an empty catalog so `init` does no heavy work on the main
        // actor and the window can draw its first frame at once. The 2.6 MB
        // snapshot (~5 000 casks, ~91 000 regex evaluations through
        // CaskCatalogIngestion) is parsed off the main actor and swapped in below.
        let emptyCatalog = CaskCatalog(casks: [], fetchedAt: .distantPast)
        self.coordinator = AdoptionCoordinator(
            scanner: scanner,
            backend: backend,
            catalog: emptyCatalog,
            scanDirectories: InventoryScanner.defaultScanDirectories
        )
        self.updateCoordinator = UpdateCoordinator(
            scanner: scanner,
            homebrew: backend,
            macAppStore: macAppStore,
            microsoftAutoUpdate: microsoftAutoUpdate,
            catalog: emptyCatalog,
            httpFetcher: httpFetcher,
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
        self.updateCoordinator = UpdateCoordinator(
            scanner: scanner,
            homebrew: backend,
            macAppStore: macAppStore,
            microsoftAutoUpdate: microsoftAutoUpdate,
            catalog: catalog,
            httpFetcher: httpFetcher,
            scanDirectories: scanDirectories
        )
    }

    /// The currently selected report, if any.
    public var selectedReport: AppReport? {
        guard let selectedReportID else { return nil }
        return reports.first { $0.id == selectedReportID }
    }

    /// The reports visible under the active ``listFilter``. Filtering leans on the
    /// update reports where present and degrades gracefully before the first
    /// update check completes (an update-based filter is simply empty until then).
    public var filteredReports: [AppReport] {
        switch listFilter {
        case .all:
            return reports
        case .updates:
            return reports.filter { updateReports[$0.app.bundlePath]?.hasUpdate == true }
        case .selfUpdating:
            return reports.filter { updateReports[$0.app.bundlePath]?.isSelfUpdating == true }
        case .unassigned:
            return reports.filter { report in
                if let update = updateReports[report.app.bundlePath] { return update.isUnassigned }
                return report.matches.isEmpty
            }
        case .problems:
            return reports.filter { report in
                let hasSourceProblem = updateReports[report.app.bundlePath]?.hasSourceProblem == true
                return hasSourceProblem || failedOutcome(for: report.app.bundlePath)
            }
        }
    }

    /// The number of reports each filter would show, for the segmented control.
    public func count(for filter: AppListFilter) -> Int {
        switch filter {
        case .all: return reports.count
        case .updates: return reports.filter { updateReports[$0.app.bundlePath]?.hasUpdate == true }.count
        case .selfUpdating: return reports.filter { updateReports[$0.app.bundlePath]?.isSelfUpdating == true }.count
        case .unassigned:
            return reports.filter { report in
                if let update = updateReports[report.app.bundlePath] { return update.isUnassigned }
                return report.matches.isEmpty
            }.count
        case .problems:
            return reports.filter { report in
                let hasSourceProblem = updateReports[report.app.bundlePath]?.hasSourceProblem == true
                return hasSourceProblem || failedOutcome(for: report.app.bundlePath)
            }.count
        }
    }

    private func failedOutcome(for bundlePath: String) -> Bool {
        guard let message = updateOutcomes[bundlePath] else { return false }
        return !message.hasPrefix("Aktualisiert")
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

        // Kick off update detection without holding the scan open: it re-scans,
        // probes Sparkle feeds over the network and runs `mas`/`msupdate`, so it
        // streams its results in on its own schedule and never blocks the list.
        Task { await self.checkForUpdates() }
    }

    /// Detect available updates for every app, per source, off the main actor.
    ///
    /// This is the read-only half of phase 2/3: it never launches an upgrade, it
    /// only classifies. Each source degrades independently — a missing tool or an
    /// unreachable feed yields `unbekannt`, never a fabricated update.
    public func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        await catalogLoad?.value

        let coordinator = self.updateCoordinator
        let produced = await Task.detached { await coordinator.makeUpdateReports() }.value

        var byPath: [String: AppUpdateReport] = [:]
        byPath.reserveCapacity(produced.count)
        for report in produced { byPath[report.app.bundlePath] = report }
        self.updateReports = byPath
    }

    /// The update report for a given adoption report, if one has been detected.
    public func updateReport(for report: AppReport) -> AppUpdateReport? {
        updateReports[report.app.bundlePath]
    }

    /// Every drivable update item across all detected reports, name-sorted. The
    /// single source the "Alle Updates" sheet draws from.
    public var allUpdateItems: [UpdateItem] {
        updateReports.values
            .flatMap { report in
                report.sources.compactMap { UpdateCoordinator.updateItem(for: report, source: $0) }
            }
            .sorted { $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending }
    }

    /// Whether an item belongs to an app OpenFreshr may update by default (i.e.
    /// not a withheld self-updater). Drives the sheet's default selection.
    public func isDefaultSelectable(_ item: UpdateItem) -> Bool {
        updateReports[item.app.bundlePath]?.isDefaultBatchSelectable ?? false
    }

    /// Run a single app's update through the coordinator (build → run → confirm
    /// by rescan). Used by the per-app "Aktualisieren" button.
    public func update(_ report: AppUpdateReport, source: SourceUpdate) async {
        guard let item = UpdateCoordinator.updateItem(for: report, source: source),
              let release = UpdateRelease(items: [item]) else { return }
        await run(release)
    }

    /// Run a batch of already-vetted items as one release. Returns `false` when
    /// the set could not be formed (it mixed major and regular upgrades) — the UI
    /// must keep those apart, so this is a guard, not an expected path.
    @discardableResult
    public func performUpdates(_ items: [UpdateItem]) async -> Bool {
        guard let release = UpdateRelease(items: items) else { return false }
        await run(release)
        return true
    }

    /// Execute a release, publishing per-app progress and outcomes, then refresh
    /// the affected reports from a fresh detection pass so the list reflects the
    /// rescan-confirmed truth.
    private func run(_ release: UpdateRelease) async {
        let paths = Set(release.items.map(\.app.bundlePath))
        guard updateInFlight.isDisjoint(with: paths) else { return }
        updateInFlight.formUnion(paths)
        defer { updateInFlight.subtract(paths) }

        let coordinator = self.updateCoordinator
        let result = await Task.detached { await coordinator.perform(release) }.value

        for outcome in result.outcomes {
            updateOutcomes[outcome.item.app.bundlePath] = Self.message(for: outcome)
        }
        let updated = result.updatedItems.count
        let failed = result.retryableItems.count
        if failed == 0 {
            lastUpdateMessage = updated == 1
                ? "1 App aktualisiert."
                : "\(updated) Apps aktualisiert."
        } else {
            lastUpdateMessage = "\(updated) aktualisiert, \(failed) fehlgeschlagen."
        }

        // Re-detect so states, versions and problems reflect the confirmed disk.
        await checkForUpdates()
    }

    /// A human-facing, per-app outcome line.
    private static func message(for outcome: UpdateOutcome) -> String {
        switch outcome {
        case .updated:
            return "Aktualisiert und per Scan bestätigt."
        case let .notConfirmedByRescan(item):
            // The generic "reported success but rescan disagrees" line is right,
            // but a reinstall-driven item (receipt drift, or the reinstall step of
            // a take-over) has a *nameable* cause, so say it instead of leaving
            // the user stranded.
            if item.homebrewStrategy == .reinstall || item.homebrewStrategy == .adoptThenReinstall {
                return "Homebrew führt diese App als aktuell, auf der Platte liegt aber eine ältere Version. "
                    + "Die Neuinstallation meldete Erfolg, der Scan bestätigt ihn aber nicht — die App bringt "
                    + "ihre Version vermutlich selbst mit (auto_updates). Bitte einmal manuell starten und "
                    + "aktualisieren lassen; danach erneut prüfen."
            }
            return "Das Werkzeug meldete Erfolg, der erneute Scan bestätigt ihn aber nicht."
        case let .caskError(_, message):
            return "Abgebrochen (CaskError): \(message)"
        case let .failed(_, reason):
            return reason.explanation
        }
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

/// The sidebar filters required by phase 3: the four the spec names, plus the
/// default "all". Each maps to a predicate in ``AppViewModel/filteredReports``.
public enum AppListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case updates
    case selfUpdating
    case unassigned
    case problems

    public var id: String { rawValue }

    /// The short, German control label.
    public var label: String {
        switch self {
        case .all: return "Alle"
        case .updates: return "Updates"
        case .selfUpdating: return "Selbst-aktualisierend"
        case .unassigned: return "Nicht zugeordnet"
        case .problems: return "Fehler"
        }
    }

    /// An SF Symbol for the filter, for a compact menu.
    public var systemImage: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .updates: return "arrow.down.circle"
        case .selfUpdating: return "arrow.triangle.2.circlepath"
        case .unassigned: return "questionmark.square.dashed"
        case .problems: return "exclamationmark.triangle"
        }
    }
}
