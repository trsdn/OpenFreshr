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

    /// Where the loaded catalog came from (network / cache / bundled snapshot),
    /// so the UI can show its provenance.
    public private(set) var catalogOrigin: CaskCatalogOrigin?

    /// When the catalog was last checked against the server. Differs from the age
    /// after a `304`: the data is old but was just re-validated.
    public private(set) var catalogCheckedAt: Date?

    /// When the loaded catalog's data was last fetched fresh, for the provenance
    /// line. Does not move on a `304`, so the age keeps growing honestly.
    public private(set) var catalogFetchedAt: Date?

    /// The visible state of the "Katalog aktualisieren" action.
    public private(set) var catalogStatus: CatalogStatus = .upToDate

    /// The install-popularity table that rides along with a network/cache load.
    /// Not surfaced yet — it backs phase 5's ranked catalog search — but it is
    /// fetched and cached now so that phase starts with data already present.
    public private(set) var installAnalytics: CaskInstallAnalytics?

    /// The loaded cask catalog, published so phase 5's catalog view can build a
    /// search index over it. `nil` until the first load completes; the catalog UI
    /// shows a loading state until then. Read-only for the UI; still owned and
    /// mutated only through ``publishCatalog(_:)``.
    public private(set) var loadedCatalog: CaskCatalog?

    /// The row currently selected in the list.
    public var selectedReportID: AppReport.ID?

    /// Tokens/apps whose adoption is in flight, keyed by bundle path.
    public private(set) var adoptionInFlight: Set<String> = []

    /// The most recent human-facing adoption outcome, for a status line.
    public private(set) var lastAdoptionMessage: String?

    /// Per-app last adoption-attempt outcome, keyed by bundle path, for the row
    /// itself — mirrors ``updateOutcomes``/``uninstallOutcomes``. Only ever
    /// populated on failure: a confirmed adoption makes the "Manage with
    /// Homebrew" button disappear (``AppReport/managedCaskToken`` becomes
    /// non-nil), so there is nothing left to show a success line on.
    public private(set) var adoptionOutcomes: [String: String] = [:]

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

    /// Bundle paths whose uninstall is in flight (#40), tracked separately from
    /// ``updateInFlight`` so a row's spinner never claims "Updating …" for an
    /// action that is actually removing the app.
    public private(set) var uninstallInFlight: Set<String> = []

    /// Per-app last uninstall outcome message, keyed by bundle path. Only ever
    /// populated on failure: a confirmed uninstall removes the app from
    /// ``reports`` on the following rescan, so there is no row left to show a
    /// success line on.
    public private(set) var uninstallOutcomes: [String: String] = [:]

    /// The most recent human-facing update outcome, for the status line.
    public private(set) var lastUpdateMessage: String?

    /// The sidebar filter the user has selected.
    public var listFilter: AppListFilter = .all

    /// Rebuilt once the catalog finishes loading; starts over an empty catalog so
    /// the first frame is not blocked on parsing the snapshot.
    private var coordinator: AdoptionCoordinator
    private let backend: HomebrewBackend

    /// Owns **verify managed → uninstall → confirm** (#40). Never rebuilt
    /// alongside ``coordinator`` — it only needs the backend, not the catalog.
    private let uninstallCoordinator: UninstallCoordinator
    private let scanner: InventoryScanner
    private let scanDirectories: [String]

    /// The update-side coordinator, wired to the real platform implementations.
    /// Rebuilt alongside ``coordinator`` when the catalog loads. A value type, so
    /// swapping it is all the next update check needs to see the real catalog.
    private var updateCoordinator: UpdateCoordinator
    @ObservationIgnored private var aiUpdateAssistant: any AIUpdateAssisting
    private let macAppStore: MacAppStoreBackend
    private let microsoftAutoUpdate: MicrosoftAutoUpdateBackend
    private let httpFetcher: any HTTPFetching

    /// Loads the catalog with the network → cache → snapshot order and keeps the
    /// on-disk cache safe (it is only ever re-ingested through the API form). A
    /// value type, captured into off-main tasks for the actual load/refresh.
    private let catalogProvider: CaskCatalogProvider

    /// A refresh in flight, so the manual action and the stale-startup refresh do
    /// not stack.
    private var catalogRefresh: Task<Void, Never>?

    /// Catalog older than this at launch triggers a background refresh; a fresher
    /// one is left as-is so start-up does not re-download ~18 MB every time.
    private static let catalogRefreshThreshold: TimeInterval = 24 * 3_600

    /// The trust chain consulted before any replacement. Built once over the real
    /// signature inspector and the on-disk JSON trust store; a value type holding a
    /// shared store reference, so it survives coordinator rebuilds and both
    /// coordinators observe the same trust decisions.
    private let trustGate: TrustGate

    /// Cached per-app trust pictures, keyed by bundle path. Populated lazily and
    /// off the main actor by ``evaluateTrust(for:)`` because it shells out to
    /// `codesign`/`spctl`; the UI reads whatever is cached and degrades to "not yet
    /// evaluated" before then.
    public private(set) var trustEvaluations: [String: TrustEvaluation] = [:]

    /// The one-shot, off-main catalog load. ``scan()`` awaits it so the first scan
    /// never classifies against the empty placeholder catalog; by the time it
    /// completes the loaded catalog has already been published on the main actor.
    private var catalogLoad: Task<Void, Never>?

    // MARK: Phase 6 — background check scheduling & menu-bar status

    /// Persists the timestamp of the last successful update check across launches.
    /// Assigned in ``init()``; the same store backs ``backgroundChecker``.
    private let lastCheckStore: any LastCheckStoring

    /// Gates due-ness and single-flight for scheduled/manual background checks.
    private let backgroundChecker: BackgroundUpdateCheckCoordinator

    /// The detection task the most recent ``scan()`` launched, tracked so a
    /// background check can await it rather than racing the fire-and-forget task.
    private var pendingUpdateCheck: Task<Void, Never>?

    /// The periodic check cadence. Persisted; setting it pushes the new interval to
    /// the coordinator so the next wake-up honours it. Bound by the Settings scene.
    public var checkInterval: UpdateCheckInterval = .daily {
        didSet {
            guard checkInterval != oldValue else { return }
            UserDefaults.standard.set(checkInterval.rawValue, forKey: Self.intervalDefaultsKey)
            backgroundChecker.updateInterval(checkInterval)
        }
    }

    /// Which coding-agent CLI, if any, "Update with AI" hands a
    /// ``UpdateBucket/manual`` app to. Off by default — this is opt-in, per the
    /// weaker safety story documented on ``AIAgentKind``.
    public var aiAgentKind: AIAgentKind = .none {
        didSet {
            guard aiAgentKind != oldValue else { return }
            UserDefaults.standard.set(aiAgentKind.rawValue, forKey: Self.aiAgentKindDefaultsKey)
        }
    }

    /// Appended after the agent's base invocation — starts at the one verified
    /// autonomy flag for the selected agent and is fully editable, since GitHub
    /// Copilot CLI in particular has no single "allow everything" flag to default
    /// to (see ``AIAgentKind/defaultAutonomyArguments``).
    public var aiAgentExtraArguments: String = "" {
        didSet {
            guard aiAgentExtraArguments != oldValue else { return }
            UserDefaults.standard.set(aiAgentExtraArguments, forKey: Self.aiAgentExtraArgumentsDefaultsKey)
        }
    }

    /// A person's override when the built-in candidate paths do not find the
    /// selected agent's CLI. Keyed by agent so switching agents does not lose the
    /// other's path.
    public var aiAgentCustomPaths: [AIAgentKind: String] = [:] {
        didSet {
            guard aiAgentCustomPaths != oldValue else { return }
            Self.saveAIAgentCustomPaths(aiAgentCustomPaths)
            aiUpdateAssistant = SystemAIUpdateAssistant(
                processRunner: SystemProcessRunner(), fileSystem: SystemFileSystem(),
                customPaths: aiAgentCustomPaths)
        }
    }

    /// When the last successful check completed, mirrored from the persisted store
    /// so the menu bar can show "last checked … ago". `nil` until the first check.
    public private(set) var lastSuccessfulCheck: Date?

    /// `true` once a detection has completed this session, so the menu bar knows to
    /// trust the live count over the persisted one.
    public private(set) var hasCompletedUpdateCheck = false

    /// The available-update count persisted from the last session, shown by the
    /// menu bar until this session's first detection completes.
    public private(set) var lastKnownAvailableUpdateCount = 0

    /// Whether the app shows a Dock icon (regular) or runs menu-bar-only
    /// (accessory). Persisted; the app delegate applies the matching activation
    /// policy on launch and whenever this changes. The view model stays AppKit-free.
    public var showsDockIcon: Bool = true {
        didSet {
            guard showsDockIcon != oldValue else { return }
            UserDefaults.standard.set(showsDockIcon, forKey: Self.showsDockIconDefaultsKey)
            onShowsDockIconChange?(showsDockIcon)
        }
    }

    /// Whether a system notification is raised when a background check finds new
    /// updates. Off by default; delivery degrades silently without permission.
    public var notifyOnNewUpdates: Bool = false {
        didSet {
            guard notifyOnNewUpdates != oldValue else { return }
            UserDefaults.standard.set(notifyOnNewUpdates, forKey: Self.notifyOnNewUpdatesDefaultsKey)
        }
    }

    /// Set by the app delegate to apply the Dock-icon activation policy.
    public var onShowsDockIconChange: ((Bool) -> Void)?

    /// Set by the app delegate to deliver a "new updates found" notification. The
    /// `Int` is the new available-update count. Only called when enabled.
    public var onNewUpdatesDetected: ((Int) -> Void)?

    /// Suppress exactly one automatic window-appear scan. Set at launch when the
    /// app starts menu-bar-only: the window `WindowGroup` briefly auto-creates is
    /// dismissed, and we do not want its `.task` to fire a network scan on every
    /// headless relaunch (that would defeat "a restart does not re-check"). A
    /// window the *user* later opens still scans normally.
    public var suppressNextWindowScan = false

    public init() {
        let fileSystem = SystemFileSystem()
        let processRunner = SystemProcessRunner()
        let backend = HomebrewBackend(processRunner: processRunner, fileSystem: fileSystem)
        let scanner = InventoryScanner(fileSystem: fileSystem)

        self.backend = backend
        self.uninstallCoordinator = UninstallCoordinator(backend: backend)
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

        self.ecosystemCoordinator = EcosystemCoordinator(ecosystems: [
            HomebrewFormulaEcosystem(processRunner: processRunner, fileSystem: fileSystem),
            NpmEcosystem(processRunner: processRunner, fileSystem: fileSystem),
            PnpmEcosystem(processRunner: processRunner, fileSystem: fileSystem),
            PipxEcosystem(processRunner: processRunner, fileSystem: fileSystem),
            MacOSUpdateEcosystem(processRunner: processRunner, fileSystem: fileSystem),
        ])

        self.aiUpdateAssistant = SystemAIUpdateAssistant(
            processRunner: processRunner, fileSystem: fileSystem,
            customPaths: Self.loadAIAgentCustomPaths())

        // The live catalog provider: a real Application-Support cache plus the
        // bundled snapshot as the offline/first-run floor. The cache is read back
        // *only* through CaskCatalogIngestion (see the provider), so a tampered
        // file cannot inject internal identity fields.
        self.catalogProvider = CaskCatalogProvider(
            httpFetcher: httpFetcher,
            cacheStore: FileCatalogCacheStore(),
            bundledSnapshot: { Self.loadBundledSnapshot() }
        )

        // The trust chain: real signature inspection over the shared process
        // runner, persisted to a JSON file in Application Support. Both
        // coordinators are handed this same gate so a first-use baseline recorded
        // by one is seen by the other.
        let trustGate = TrustGate(
            inspector: SystemCodeSignatureInspector(processRunner: processRunner, fileSystem: fileSystem),
            store: JSONFileTrustStore()
        )
        self.trustGate = trustGate

        // Start over an empty catalog so `init` does no heavy work on the main
        // actor and the window can draw its first frame at once. The 2.6 MB
        // snapshot (~5 000 casks, ~91 000 regex evaluations through
        // CaskCatalogIngestion) is parsed off the main actor and swapped in below.
        let emptyCatalog = CaskCatalog(casks: [], fetchedAt: .distantPast)
        self.coordinator = AdoptionCoordinator(
            scanner: scanner,
            backend: backend,
            catalog: emptyCatalog,
            scanDirectories: InventoryScanner.defaultScanDirectories,
            trustGate: trustGate
        )
        self.updateCoordinator = UpdateCoordinator(
            scanner: scanner,
            homebrew: backend,
            macAppStore: macAppStore,
            microsoftAutoUpdate: microsoftAutoUpdate,
            catalog: emptyCatalog,
            httpFetcher: httpFetcher,
            scanDirectories: InventoryScanner.defaultScanDirectories,
            trustGate: trustGate
        )

        // Phase 6 — background update-check scheduling and menu-bar status. The
        // last successful check is persisted so a relaunch does not immediately
        // re-scan; the coordinator gates due-ness and guarantees a scheduled and a
        // manual check never overlap. The last known update count is cached
        // separately so the menu bar can show status before this session's first
        // scan completes.
        let lastCheckStore = JSONFileLastCheckStore()
        let interval = Self.loadCheckInterval()
        self.lastCheckStore = lastCheckStore
        self.backgroundChecker = BackgroundUpdateCheckCoordinator(interval: interval, store: lastCheckStore)
        self.checkInterval = interval
        self.lastSuccessfulCheck = lastCheckStore.lastSuccessfulCheck()
        self.lastKnownAvailableUpdateCount = UserDefaults.standard.integer(forKey: Self.lastKnownCountDefaultsKey)
        self.showsDockIcon = Self.loadShowsDockIcon()
        self.notifyOnNewUpdates = Self.loadNotifyOnNewUpdates()
        self.aiAgentKind = Self.loadAIAgentKind()
        self.aiAgentExtraArguments = Self.loadAIAgentExtraArguments()
        self.aiAgentCustomPaths = Self.loadAIAgentCustomPaths()
        // Starting menu-bar-only: skip the first (auto-created, immediately
        // dismissed) window's scan so a headless relaunch stays quiet.
        self.suppressNextWindowScan = !Self.loadShowsDockIcon()

        // Load the best *offline* catalog (cache → snapshot) off the main actor and
        // publish it. This is what the first scan gates on, so it must stay fast —
        // the network refresh below is deliberately fire-and-forget.
        self.catalogLoad = Task { [weak self] in
            guard let self else { return }
            let provider = self.catalogProvider
            let load = await Task.detached(priority: .userInitiated) {
                provider.loadInitial()
            }.value
            self.publishCatalogLoad(load)

            // If the offline catalog is stale, refresh in the background. This does
            // not gate the first scan; fresher data swaps in when it lands.
            if load.catalog.age() > Self.catalogRefreshThreshold {
                self.refreshCatalog()
            }
        }
    }

    /// Swap the freshly loaded catalog into a rebuilt coordinator on the main
    /// actor. ``AdoptionCoordinator`` is a value type, so replacing it is all it
    /// takes for the next scan to see the real catalog.
    private func publishCatalog(_ catalog: CaskCatalog) {
        self.catalogAge = catalog.age()
        self.loadedCatalog = catalog
        self.coordinator = AdoptionCoordinator(
            scanner: scanner,
            backend: backend,
            catalog: catalog,
            scanDirectories: scanDirectories,
            trustGate: trustGate
        )
        self.updateCoordinator = UpdateCoordinator(
            scanner: scanner,
            homebrew: backend,
            macAppStore: macAppStore,
            microsoftAutoUpdate: microsoftAutoUpdate,
            catalog: catalog,
            httpFetcher: httpFetcher,
            scanDirectories: scanDirectories,
            trustGate: trustGate
        )
    }

    /// Publish a full catalog load: swap the catalog into the coordinators (via
    /// ``publishCatalog``) and surface its provenance, age and refresh state.
    private func publishCatalogLoad(_ load: CaskCatalogLoad) {
        publishCatalog(load.catalog)
        self.catalogOrigin = load.origin
        self.catalogCheckedAt = load.checkedAt
        self.catalogFetchedAt = load.catalog.fetchedAt
        // Keep any analytics we already had if this load carried none (the bundled
        // snapshot has no analytics, so a snapshot fallback must not drop them).
        if let analytics = load.analytics {
            self.installAnalytics = analytics
        }
        if let error = load.error {
            self.catalogStatus = .failed(Self.describeCatalog(error))
        } else {
            self.catalogStatus = .upToDate
        }
    }

    /// Refresh the catalog from the network in the background. Safe to call from a
    /// button: it manages its own task and coalesces overlapping requests, and a
    /// failure keeps the last-known catalog while reporting the reason.
    public func refreshCatalog() {
        guard catalogRefresh == nil else { return }
        catalogStatus = .loading
        let provider = self.catalogProvider
        catalogRefresh = Task { [weak self] in
            let load = await Task.detached(priority: .userInitiated) {
                await provider.refresh()
            }.value
            guard let self else { return }
            self.catalogRefresh = nil
            self.publishCatalogLoad(load)
            // A fresh network catalog can change classifications; reflect it once,
            // but only when a prior scan already produced reports so we do not race
            // the very first scan.
            if load.origin == .network, !self.reports.isEmpty, !self.isScanning {
                Task { await self.scan() }
            }
        }
    }

    /// Manually invalidate the on-disk cache and refresh. The in-memory catalog
    /// stays until the refresh replaces it, so the UI never blanks.
    public func invalidateCatalogCache() {
        try? catalogProvider.clearCache()
        refreshCatalog()
    }

    /// A short provenance line for the status bar, e.g.
    /// "Catalog from today 09:12" or "Bundled snapshot from June 3, 2025".
    public var catalogProvenanceText: String {
        guard let origin = catalogOrigin else { return String(localized: "Loading catalog …") }
        let when = catalogFetchedAt.map { Self.relativeCatalogDate($0) }
        switch origin {
        case .network, .cache:
            if let when { return String(localized: "Catalog from \(when)") }
            return String(localized: "Catalog loaded")
        case .bundledSnapshot:
            if let when { return String(localized: "Bundled snapshot from \(when)") }
            return String(localized: "Bundled catalog")
        case .empty:
            return String(localized: "Loading catalog …")
        }
    }

    private static func describeCatalog(_ error: CatalogRefreshError) -> String {
        switch error.kind {
        case .network:
            return String(localized: "Fetch failed – the last snapshot stays active.")
        case .ingestion:
            return String(localized: "Response unreadable – the last snapshot stays active.")
        }
    }

    private static func relativeCatalogDate(
        _ date: Date,
        calendar: Calendar = .current
    ) -> String {
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        if calendar.isDateInToday(date) { return String(localized: "today \(time.string(from: date))") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday \(time.string(from: date))") }
        let full = DateFormatter()
        full.dateStyle = .long
        full.timeStyle = .none
        return full.string(from: date)
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

    /// Every app in the bucket a person would look for it in, groups in reading
    /// order and apps by name. An app whose update check has not finished yet is
    /// listed under "can't tell" rather than guessed at.
    public var bucketedReports: [(bucket: UpdateBucket, reports: [AppReport])] {
        let grouped = Dictionary(grouping: reports) {
            updateReports[$0.app.bundlePath]?.bucket ?? .cannotTell
        }
        return UpdateBucket.allCases.compactMap { bucket in
            guard let members = grouped[bucket], !members.isEmpty else { return nil }
            return (
                bucket,
                members.sorted {
                    $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending
                }
            )
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

    /// The per-app outcome line for a confirmed update; compared against to tell
    /// failures from successes, so it must stay the single source of that text.
    private static var updatedMessage: String { String(localized: "Updated and confirmed by scan.") }

    func failedOutcome(for bundlePath: String) -> Bool {
        guard let message = updateOutcomes[bundlePath] else { return false }
        return message != Self.updatedMessage
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

        self.reports = reports.sorted {
            $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending
        }
        self.homebrewAvailable = available

        // Kick off update detection without holding the scan open: it re-scans,
        // probes Sparkle feeds over the network and runs `mas`/`msupdate`, so it
        // streams its results in on its own schedule and never blocks the list.
        // Tracked so a background check can await its completion (see
        // ``runScheduledCheckIfDue(now:)``) without racing the fire-and-forget task.
        self.pendingUpdateCheck = Task { await self.checkForUpdates() }
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
        let ecosystems = self.ecosystemCoordinator
        async let produced = Task.detached { await coordinator.makeUpdateReports() }.value
        async let packages = ecosystems.checkAll()

        var byPath: [String: AppUpdateReport] = [:]
        let (appReports, packageReports) = await (produced, packages)
        byPath.reserveCapacity(appReports.count)
        for report in appReports { byPath[report.app.bundlePath] = report }
        self.updateReports = byPath
        self.ecosystemReports = packageReports

        // Phase 6: any completed detection — whether triggered by the window, the
        // menu bar's "Check Now", or the background scheduler — advances the
        // persisted schedule so a relaunch (or a background tick right afterwards)
        // does not immediately re-scan, and refreshes the status the menu bar caches
        // for display before this session's first scan.
        let completedAt = Date()
        lastCheckStore.recordSuccessfulCheck(at: completedAt)
        lastSuccessfulCheck = completedAt
        hasCompletedUpdateCheck = true
        lastKnownAvailableUpdateCount = availableUpdateCount
        UserDefaults.standard.set(lastKnownAvailableUpdateCount, forKey: Self.lastKnownCountDefaultsKey)
    }

    @ObservationIgnored private var homepageCache: (casks: Int, byToken: [String: String])?

    /// The vendor's website for an app, taken from the cask the app was matched to.
    /// `nil` when the app matched no cask or the cask lists no web address.
    public func websiteURL(for report: AppReport) -> URL? {
        guard let casks = loadedCatalog?.casks, !report.matches.isEmpty else { return nil }
        if homepageCache?.casks != casks.count {
            homepageCache = (
                casks.count,
                Dictionary(
                    casks.compactMap { cask in cask.homepage.map { (cask.token, $0) } },
                    uniquingKeysWith: { first, _ in first })
            )
        }
        for match in report.matches {
            if let text = homepageCache?.byToken[match.caskToken], let url = URL(string: text),
                ["https", "http"].contains(url.scheme?.lowercased())
            {
                return url
            }
        }
        return nil
    }

    /// Package-manager and system sources that are not apps (Homebrew formulae
    /// today; macOS and language package managers follow). Empty until the first
    /// ``checkForUpdates()`` completes.
    public private(set) var ecosystemReports: [EcosystemReport] = []

    @ObservationIgnored private let ecosystemCoordinator: EcosystemCoordinator

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
    ///
    /// `acknowledgeTeamChange` is set only when the user has explicitly opted in to
    /// a detected publisher (team-ID) change for this app in the confirmation UI.
    /// Without it, the trust gate blocks the replacement before any backend runs.
    public func update(
        _ report: AppUpdateReport,
        source: SourceUpdate,
        acknowledgeTeamChange: Bool = false
    ) async {
        guard let item = UpdateCoordinator.updateItem(for: report, source: source),
            let release = UpdateRelease(items: [item])
        else { return }
        await run(
            release,
            acknowledgingTeamChanges: acknowledgeTeamChange ? [item.app.bundlePath] : []
        )
    }

    /// Whether OpenFreshr can install `package` itself, for the row's Update-vs-Open
    /// choice.
    public func canAutomaticallyUpdate(_ package: OutdatedPackage) -> Bool {
        ecosystemCoordinator.canAutomaticallyUpdate(package)
    }

    /// Install one outdated package and confirm the ecosystem's own report.
    public func updatePackage(_ package: OutdatedPackage) async {
        let key = package.id
        guard !updateInFlight.contains(key) else { return }
        updateInFlight.insert(key)
        defer { updateInFlight.remove(key) }

        let ecosystems = self.ecosystemCoordinator
        let results = await ecosystems.update([package])
        guard let result = results.first else { return }
        updateOutcomes[key] =
            result.isVerified
            ? Self.updatedMessage
            : (result.stillOutdated == true
                ? String(localized: "Reported success, but the package is still outdated.")
                : (result.action.explanation ?? ""))

        if let index = ecosystemReports.firstIndex(where: { $0.kind == package.ecosystem }) {
            ecosystemReports[index].check = checkAfterVerifiedUpdate(for: package.ecosystem, result: result)
        }
    }

    /// The ecosystem's check with `package` removed when the update was verified,
    /// or unchanged otherwise — a light local patch so the row disappears at once
    /// instead of waiting for the next full ``checkForUpdates()``.
    private func checkAfterVerifiedUpdate(for kind: EcosystemKind, result: PackageUpdateResult) -> EcosystemCheck {
        guard result.isVerified, let current = ecosystemReports.first(where: { $0.kind == kind })?.check
        else {
            return ecosystemReports.first(where: { $0.kind == kind })?.check ?? .unknown(.unparsableOutput)
        }
        let remaining = current.packages.filter { $0.id != result.package.id }
        return remaining.isEmpty ? .upToDate : .outdated(remaining)
    }

    /// Whether "Update with AI" can be offered right now: an agent is selected
    /// and its CLI was actually found. Checked fresh each time rather than
    /// cached, since Settings can change it, or the CLI can appear/disappear,
    /// between checks.
    public func isAIAgentAvailable() -> Bool {
        aiAgentKind != .none && aiUpdateAssistant.resolvedPath(for: aiAgentKind) != nil
    }

    /// Hand a ``UpdateBucket/manual`` app's update to the configured agent CLI.
    ///
    /// Deliberately never offered for a source the trust gate has blocked — see
    /// ``AIAgentKind`` — which the caller enforces by only ever calling this for
    /// an app in the `.manual` bucket: such an app has no OpenFreshr-drivable
    /// command at all, so there is no trust-gated replacement for this to route
    /// around. The agent's own claim of success is exactly that — a claim — so
    /// this still confirms by rescanning afterward, the same as every backend.
    public func updateWithAI(_ report: AppUpdateReport, bucket: UpdateBucket) async {
        let path = report.app.bundlePath
        guard !updateInFlight.contains(path) else { return }
        updateInFlight.insert(path)
        defer { updateInFlight.remove(path) }

        let request = AIUpdateRequest(
            appName: report.app.displayName,
            bundlePath: path,
            installedVersion: report.app.displayVersion,
            availableVersion: report.primarySource?.state.availableVersion,
            reason: aiReason(for: report, bucket: bucket)
        )
        let assistant = aiUpdateAssistant
        let agent = aiAgentKind
        let extraArguments = aiAgentExtraArguments.split(separator: " ").map(String.init)
        let outcome = await Task.detached {
            assistant.run(request, agent: agent, extraArguments: extraArguments, timeout: 300)
        }.value

        updateOutcomes[path] = outcome.output.isEmpty ? Self.updatedMessage : outcome.output

        // Confirm by rescanning — the agent's own report of success is never
        // trusted on its own, the same rule every other backend follows.
        await checkForUpdates()
        if outcome.didReportSuccess, let refreshed = updateReports[path], !refreshed.hasUpdate {
            updateOutcomes[path] = Self.updatedMessage
        }
    }

    /// What the agent is told about why it is being asked, per the bucket the
    /// row was in when the person chose it. `.manual` states OpenFreshr's own
    /// reason; the other buckets say plainly that the person chose the agent
    /// over an available alternative, folding in the last recorded failure (a
    /// trust block, a sudo refusal, …) when there is one, so the agent is not
    /// left guessing at a "no automatic way" that is not actually true here.
    private func aiReason(for report: AppUpdateReport, bucket: UpdateBucket) -> String {
        if let manualReason = report.manualReason { return manualReason.explanation }
        let path = report.app.bundlePath
        let priorFailure = failedOutcome(for: path) ? updateOutcomes[path] : nil
        switch bucket {
        case .ready:
            if let priorFailure {
                return String(
                    localized: "OpenFreshr's own attempt to update this failed: \(priorFailure)")
            }
            return String(
                localized: "OpenFreshr could install this itself, but you chose the AI agent instead.")
        case .ownUpdater:
            return String(
                localized: "This app has its own updater, but you chose the AI agent instead.")
        case .manual, .cannotTell, .upToDate:
            return String(localized: "No automatic way to update it.")
        }
    }

    /// Run a batch of already-vetted items as one release. Returns `false` when
    /// the set could not be formed (it mixed major and regular upgrades) — the UI
    /// must keep those apart, so this is a guard, not an expected path.
    ///
    /// `acknowledgedTeamChanges` holds the bundle paths the user explicitly opted
    /// in for; every other item whose team ID changed is blocked before its backend
    /// runs, so a batch can never wave a publisher change through unnoticed.
    @discardableResult
    public func performUpdates(
        _ items: [UpdateItem],
        acknowledgedTeamChanges: Set<String> = []
    ) async -> Bool {
        guard let release = UpdateRelease(items: items) else { return false }
        await run(release, acknowledgingTeamChanges: acknowledgedTeamChanges)
        return true
    }

    /// Execute a release, publishing per-app progress and outcomes, then refresh
    /// the affected reports from a fresh detection pass so the list reflects the
    /// rescan-confirmed truth.
    private func run(_ release: UpdateRelease, acknowledgingTeamChanges: Set<String> = []) async {
        let paths = Set(release.items.map(\.app.bundlePath))
        guard updateInFlight.isDisjoint(with: paths) else { return }
        updateInFlight.formUnion(paths)
        defer { updateInFlight.subtract(paths) }

        let coordinator = self.updateCoordinator
        let result = await Task.detached {
            await coordinator.perform(release, acknowledgingTeamChanges: acknowledgingTeamChanges)
        }.value

        for outcome in result.outcomes {
            updateOutcomes[outcome.item.app.bundlePath] = Self.message(for: outcome)
        }
        let updated = result.updatedItems.count
        let failed = result.retryableItems.count
        if failed == 0 {
            lastUpdateMessage =
                updated == 1
                ? String(localized: "1 app updated.")
                : String(localized: "\(updated) apps updated.")
        } else {
            lastUpdateMessage = String(localized: "\(updated) updated, \(failed) failed.")
        }

        // Re-detect so states, versions and problems reflect the confirmed disk.
        await checkForUpdates()
    }

    /// A human-facing, per-app outcome line.
    private static func message(for outcome: UpdateOutcome) -> String {
        switch outcome {
        case .updated:
            return Self.updatedMessage
        case let .notConfirmedByRescan(item):
            // The generic "reported success but rescan disagrees" line is right,
            // but a reinstall-driven item (receipt drift, or the reinstall step of
            // a take-over) has a *nameable* cause, so say it instead of leaving
            // the user stranded.
            if item.homebrewStrategy == .reinstall || item.homebrewStrategy == .adoptThenReinstall {
                return String(
                    localized:
                        "Homebrew lists this app as up to date, but an older version is on disk. The reinstall reported success, but the scan does not confirm it — the app probably brings its own version (auto_updates). Please launch it manually once and let it update; then check again."
                )
            }
            return String(localized: "The tool reported success, but the renewed scan does not confirm it.")
        case let .caskError(_, message):
            return String(localized: "Aborted (CaskError): \(message)")
        case let .failed(_, reason):
            return reason.explanation
        case let .blockedByTrust(_, block):
            return block.explanation
        }
    }

    /// Attempt to adopt `app`, then refresh the affected report from the
    /// coordinator's rescan-confirmed result.
    ///
    /// This is the standalone "Manage with Homebrew" action: unlike the
    /// adoption folded into "Update" (``UpdateCoordinator``'s
    /// `.adoptThenReinstall`, for an app that also has a pending update), this
    /// is offered for an app that is already at the cask's current version —
    /// where a take-over is the *only* thing to do, so nothing folds it into
    /// another action for the button to ride along with.
    public func adopt(_ app: InstalledApp, acknowledgeTeamChange: Bool = false) async {
        guard !adoptionInFlight.contains(app.bundlePath) else { return }
        adoptionInFlight.insert(app.bundlePath)
        defer { adoptionInFlight.remove(app.bundlePath) }
        adoptionOutcomes[app.bundlePath] = nil

        let coordinator = self.coordinator
        let result = await Task.detached {
            coordinator.adopt(app, acknowledgingTeamChange: acknowledgeTeamChange)
        }.value

        switch result {
        case let .adopted(report):
            lastAdoptionMessage = String(localized: "\(app.displayName) is now managed by Homebrew.")
            // The coordinator already rescanned and re-classified this app to
            // confirm the adoption; reuse that verified report instead of
            // triggering a second full inventory scan. Its managedCaskToken is
            // what makes the Uninstall button appear on the next render, and
            // this same replace makes the "Manage with Homebrew" button
            // disappear — both read straight off this report, not off a flag
            // this method sets.
            replace(report)
        case let .hardFailedWithCaskError(message):
            let text = String(localized: "Adoption aborted (CaskError): \(message)")
            lastAdoptionMessage = String(localized: "\(app.displayName): \(text)")
            adoptionOutcomes[app.bundlePath] = text
        case .notConfirmedByRescan:
            let text = String(
                localized: "Homebrew reported success, but the renewed scan does not confirm it.")
            lastAdoptionMessage = String(localized: "\(app.displayName): \(text)")
            adoptionOutcomes[app.bundlePath] = text
        case let .failed(reason):
            lastAdoptionMessage = String(localized: "\(app.displayName): \(reason.explanation)")
            adoptionOutcomes[app.bundlePath] = reason.explanation
        case let .notEligible(reason):
            let text = String(localized: "Cannot be adopted: \(reason.explanation)")
            lastAdoptionMessage = String(localized: "\(app.displayName): \(text)")
            adoptionOutcomes[app.bundlePath] = text
        case let .blockedByTrust(block):
            lastAdoptionMessage = String(localized: "\(app.displayName): \(block.explanation)")
            adoptionOutcomes[app.bundlePath] = block.explanation
        }
    }

    /// Remove `report`'s app via Homebrew (#40), then confirm the outcome with a
    /// fresh full scan. A no-op when Homebrew does not currently manage this app
    /// — see ``AppReport/managedCaskToken``, the same fact the Uninstall button
    /// is gated on, checked again here so a stale UI can never trigger a wrong
    /// removal.
    ///
    /// Scoped to Homebrew-managed apps only, exactly like ``UninstallCoordinator``:
    /// there is no command here that removes a `.app` bundle directly.
    public func uninstall(_ report: AppReport) async {
        guard let token = report.managedCaskToken else { return }
        let path = report.app.bundlePath
        guard !uninstallInFlight.contains(path) else { return }
        uninstallInFlight.insert(path)
        defer { uninstallInFlight.remove(path) }
        uninstallOutcomes[path] = nil

        let coordinator = self.uninstallCoordinator
        let result = await Task.detached {
            coordinator.uninstall(caskToken: token)
        }.value

        switch result {
        case .uninstalled:
            // Nothing to say: the rescan below drops this row entirely.
            break
        case .notManaged:
            // The button state was stale (someone else's action changed it
            // between the click and this call); nothing to report either.
            break
        case let .hardFailedWithCaskError(message):
            uninstallOutcomes[path] = String(localized: "Aborted (CaskError): \(message)")
        case let .failed(reason):
            uninstallOutcomes[path] = reason.explanation
        case .notConfirmedByRescan:
            uninstallOutcomes[path] = String(
                localized: "Homebrew reported success, but still lists this app as managed.")
        }

        // Re-detect so a confirmed removal drops the row and nothing downstream
        // still references a bundle that is gone.
        await scan()
    }

    // MARK: - Trust (phase 4)

    /// The cached trust picture for `app`, if one has been evaluated. Read-only and
    /// non-blocking; call ``evaluateTrust(for:)`` to populate or refresh it.
    public func trustEvaluation(for app: InstalledApp) -> TrustEvaluation? {
        trustEvaluations[app.bundlePath]
    }

    /// Evaluate (or refresh) the trust picture for `app` off the main actor and
    /// publish it. Runs `codesign`/`spctl`, so it must not block the UI; the view
    /// calls this from a `.task` and reads ``trustEvaluation(for:)`` for the result.
    /// This never mutates the trust store — enforcement records happen only when an
    /// actual replacement is authorised.
    public func evaluateTrust(for app: InstalledApp) async {
        let gate = self.trustGate
        let evaluation = await Task.detached { gate.evaluate(app) }.value
        trustEvaluations[app.bundlePath] = evaluation
    }

    /// Every stored trust decision, newest first, for the management view.
    public func storedTrustRecords() -> [TrustRecord] {
        trustGate.storedRecords().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Forget the stored baseline for one app. The next replacement treats the app
    /// as a fresh first observation — a *new* baseline, not implicit trust of the
    /// old team.
    public func resetTrust(bundleIdentifier: String) {
        trustGate.resetTrust(bundleIdentifier: bundleIdentifier)
        // Drop any cached evaluations that referenced this baseline so the UI
        // recomputes against the now-empty store on next view.
        trustEvaluations = trustEvaluations.filter { $0.value.bundleIdentifier != bundleIdentifier }
    }

    /// Forget every stored trust decision.
    public func resetAllTrust() {
        trustGate.resetAllTrust()
        trustEvaluations = [:]
    }

    private func replace(_ report: AppReport) {
        if let index = reports.firstIndex(where: { $0.id == report.id }) {
            reports[index] = report
        }
    }

    /// Ingest the catalog snapshot shipped as an app resource, if present.
    ///
    /// The snapshot is the offline/first-run floor beneath the live
    /// ``CaskCatalogProvider`` (network → cache → snapshot). It is the real
    /// Homebrew cask API shape and is ingested by the production
    /// ``CaskCatalogIngestion``, so the app matches real apps out of the box with
    /// no network and no Homebrew.
    ///
    /// - Important: Every catalog source — the live network response **and** the
    ///   on-disk refresh cache — is ingested through ``CaskCatalogIngestion`` (the
    ///   *API* form), exactly as this snapshot is, never by decoding external bytes
    ///   straight into the internal ``Cask`` `Codable` form. Only ingestion
    ///   *recovers* identity from stanzas under our own rules; decoding the
    ///   internal form would let untrusted input (including a hand-crafted cache
    ///   file) set internal safety fields (`primaryBundleIdentifiers`,
    ///   `autoUpdates`, …) directly and defeat every corroboration and veto check.
    ///   ``CaskCatalogProvider`` and ``FileCatalogCacheStore`` uphold this.
    private nonisolated static func loadBundledSnapshot() -> CaskCatalog? {
        guard let url = Bundle.main.url(forResource: "casks-snapshot", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        // Date the snapshot by its bundled file so the "catalog is N old" hint is
        // honest about how stale the shipped data is.
        let fetchedAt =
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            ?? .distantPast
        return try? CaskCatalogIngestion.decodeCatalog(fromAPIData: data, fetchedAt: fetchedAt)
    }

    // MARK: - Phase 6: menu-bar status & background update checking
    //
    // The menu bar is a *status surface*, not a second execution path: it reports
    // how many updates are available and drives the schedule, but every actual
    // replacement still flows through the window's preview/confirmation dialogs so
    // the trust gate is never bypassed. Nothing here installs anything.

    static let intervalDefaultsKey = "openfreshr.updateCheckInterval"
    static let showsDockIconDefaultsKey = "openfreshr.showsDockIcon"
    static let notifyOnNewUpdatesDefaultsKey = "openfreshr.notifyOnNewUpdates"
    static let lastKnownCountDefaultsKey = "openfreshr.lastKnownAvailableUpdateCount"
    static let aiAgentKindDefaultsKey = "openfreshr.aiAgentKind"
    static let aiAgentExtraArgumentsDefaultsKey = "openfreshr.aiAgentExtraArguments"
    static let aiAgentCustomPathsDefaultsKey = "openfreshr.aiAgentCustomPaths"

    static func loadAIAgentKind() -> AIAgentKind {
        guard let raw = UserDefaults.standard.string(forKey: aiAgentKindDefaultsKey),
            let parsed = AIAgentKind(rawValue: raw)
        else { return .none }
        return parsed
    }

    /// Seeded with the selected agent's one verified autonomy flag the first
    /// time it is picked, so the field is never blank when it first appears —
    /// but only the *last saved* text is ever read back, never recomputed from
    /// the agent, so a person's edit always wins over the built-in default.
    static func loadAIAgentExtraArguments() -> String {
        UserDefaults.standard.string(forKey: aiAgentExtraArgumentsDefaultsKey) ?? ""
    }

    static func loadAIAgentCustomPaths() -> [AIAgentKind: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: aiAgentCustomPathsDefaultsKey) as? [String: String]
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: raw.compactMap { key, value in
                AIAgentKind(rawValue: key).map { ($0, value) }
            })
    }

    static func saveAIAgentCustomPaths(_ paths: [AIAgentKind: String]) {
        let raw = Dictionary(uniqueKeysWithValues: paths.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: aiAgentCustomPathsDefaultsKey)
    }

    static func loadCheckInterval() -> UpdateCheckInterval {
        guard let raw = UserDefaults.standard.string(forKey: intervalDefaultsKey),
            let parsed = UpdateCheckInterval(rawValue: raw)
        else { return .daily }
        return parsed
    }

    static func loadShowsDockIcon() -> Bool {
        UserDefaults.standard.object(forKey: showsDockIconDefaultsKey) as? Bool ?? true
    }

    static func loadNotifyOnNewUpdates() -> Bool {
        UserDefaults.standard.bool(forKey: notifyOnNewUpdatesDefaultsKey)
    }

    /// The number of apps with an available update. This is the canonical menu-bar
    /// count and is identical *by construction* to the window's "Updates" filter —
    /// both derive from the same predicate via ``count(for:)``.
    public var availableUpdateCount: Int { count(for: .updates) }

    /// The count the menu bar should show. Once a detection has completed this
    /// session, the live count is authoritative; before that (e.g. a menu-bar-only
    /// relaunch that was not yet due to re-check) it falls back to the persisted
    /// last known count so the badge is not misleadingly empty.
    public var menuBarUpdateCount: Int {
        hasCompletedUpdateCheck ? availableUpdateCount : lastKnownAvailableUpdateCount
    }

    /// A value-type snapshot the menu-bar popover renders.
    public var menuBarStatus: MenuBarStatus {
        MenuBarStatus(
            availableUpdateCount: menuBarUpdateCount,
            lastSuccessfulCheck: lastSuccessfulCheck,
            interval: checkInterval,
            isChecking: isScanning || isCheckingUpdates
        )
    }

    /// The apps that currently have an available update, name-sorted — the short
    /// list the popover shows. Read-only: acting on them still happens in the window.
    public var appsWithAvailableUpdates: [AppUpdateReport] {
        reports.compactMap { updateReports[$0.app.bundlePath] }
            .filter(\.hasUpdate)
            .sorted { $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending }
    }

    /// The scan a window runs when it appears. It populates the list for a window
    /// the user is actually looking at, but honours ``suppressNextWindowScan`` so
    /// the throwaway window a menu-bar-only launch briefly creates does not trigger
    /// a network scan on every headless relaunch.
    public func scanOnWindowAppear() async {
        if suppressNextWindowScan {
            suppressNextWindowScan = false
            return
        }
        await scan()
    }

    /// Seconds until the next scheduled check is due, or `nil` when checking is off
    /// or nothing is scheduled yet. Drives the app delegate's wake-up loop.
    public func secondsUntilNextScheduledCheck(now: Date = Date()) -> TimeInterval? {
        backgroundChecker.secondsUntilNextCheck(now: now)
    }

    /// Change the periodic check interval, persisting it and updating the
    /// coordinator so the next wake-up honours the new cadence immediately.
    public func setCheckInterval(_ interval: UpdateCheckInterval) {
        checkInterval = interval
    }

    /// Await the update detection kicked off by the most recent ``scan()``.
    private func awaitPendingUpdateCheck() async {
        await pendingUpdateCheck?.value
    }

    /// Run one background check — a full inventory scan plus update detection — to
    /// completion, honouring single-flight, then optionally notify about newly
    /// found updates. It **only** re-scans and re-detects; it never installs.
    private func runTrackedCheck(now: Date, notify: Bool) async {
        let before = availableUpdateCount
        await scan()
        await awaitPendingUpdateCheck()
        let after = availableUpdateCount
        backgroundChecker.finishCheck(success: true, at: now)
        lastSuccessfulCheck = backgroundChecker.lastSuccessfulCheck()
        if notify, notifyOnNewUpdates, after > before {
            onNewUpdatesDetected?(after)
        }
    }

    /// Run a scheduled check, but only if one is due and none is already running.
    /// Called by the app delegate's periodic loop and once at launch; a persisted
    /// recent timestamp makes this a no-op, so a relaunch does not re-scan.
    public func runScheduledCheckIfDue(now: Date = Date()) async {
        guard backgroundChecker.beginCheckIfDue(now: now) else { return }
        await runTrackedCheck(now: now, notify: true)
    }

    /// The menu bar's "Check Now": force a check now regardless of the schedule,
    /// still single-flight so it can never overlap a scheduled or in-flight check.
    /// The user is present, so it does not raise a notification.
    public func checkNow(now: Date = Date()) async {
        guard backgroundChecker.beginCheckIfDue(now: now, force: true) else { return }
        await runTrackedCheck(now: now, notify: false)
    }
}

/// The visible state of the "Katalog aktualisieren" action, mapped to a control
/// label and symbol by the status bar.
public enum CatalogStatus: Sendable, Equatable {
    /// A refresh is in flight.
    case loading
    /// The catalog is loaded and current (fresh, cached, or the snapshot floor).
    case upToDate
    /// The last refresh failed; the reason is shown and the prior catalog stays.
    case failed(String)
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

    /// The short control label.
    public var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .updates: return String(localized: "Updates")
        case .selfUpdating: return String(localized: "Self-updating")
        case .unassigned: return String(localized: "Unassigned")
        case .problems: return String(localized: "Errors")
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
