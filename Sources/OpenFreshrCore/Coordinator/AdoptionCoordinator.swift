import Foundation

/// One app together with everything the UI needs to decide what to offer:
/// its matches, its adoption eligibility, its detected sources and — when
/// eligible — the predicted adopt outcome.
public struct AppReport: Sendable, Identifiable {
    public var app: InstalledApp
    public var matches: [AppMatch]
    public var eligibility: AdoptionEligibility
    public var sources: Set<AppSource>
    public var predictedOutcome: AdoptionOutcomePrediction?

    public init(
        app: InstalledApp,
        matches: [AppMatch],
        eligibility: AdoptionEligibility,
        sources: Set<AppSource>,
        predictedOutcome: AdoptionOutcomePrediction?
    ) {
        self.app = app
        self.matches = matches
        self.eligibility = eligibility
        self.sources = sources
        self.predictedOutcome = predictedOutcome
    }

    public var id: String { app.bundlePath }

    /// Convenience: the cask token this app may be adopted as, if any.
    public var adoptableCaskToken: String? { eligibility.caskToken }
}

/// The result of an adoption attempt, confirmed by a rescan.
///
/// The three terminal cases are kept distinct on purpose, mirroring the backend
/// but adding the rescan verdict:
///
/// * ``adopted`` — the backend reported success **and** a fresh scan shows the
///   app is now Homebrew-managed. Only this counts as done.
/// * ``hardFailedWithCaskError`` — Homebrew aborted with a `CaskError`; the app
///   is unchanged. Retryable once the cause (version) is understood.
/// * ``failed`` — any other failure, or a "success" the rescan did **not**
///   confirm (reported success but the app is still unmanaged). Retryable.
public enum AdoptionResult: Sendable {
    case adopted(AppReport)
    case hardFailedWithCaskError(message: String)
    case failed(reason: BackendFailureReason)
    case notConfirmedByRescan
    case notEligible(reason: IneligibilityReason)
    /// The trust chain refused the take-over **before** the backend ran: an
    /// unsigned/invalid bundle, a Gatekeeper rejection, or an unacknowledged
    /// team-ID change. The app is untouched.
    case blockedByTrust(TrustBlock)

    public var didAdopt: Bool {
        if case .adopted = self { return true }
        return false
    }

    /// Whether it is sensible to offer the user a retry.
    public var isRetryable: Bool {
        switch self {
        case .adopted, .notEligible, .blockedByTrust:
            return false
        case .hardFailedWithCaskError, .failed, .notConfirmedByRescan:
            return true
        }
    }

    /// The trust block, when the trust chain refused the take-over.
    public var trustBlock: TrustBlock? {
        if case let .blockedByTrust(block) = self { return block }
        return nil
    }
}

/// Owns the phase 1 sequence **scan → match → adopt → rescan → confirm**.
///
/// This lives in the core, never in a view, so the whole flow is testable
/// without SwiftUI and so success is defined by data (a confirming rescan)
/// rather than by a button handler believing the backend.
public struct AdoptionCoordinator: Sendable {

    private let scanner: InventoryScanner
    private let backend: any AdoptingBackend
    private let catalog: CaskCatalog
    private let scanDirectories: [String]
    /// The trust chain consulted before a take-over replaces anything on disk.
    /// `nil` leaves the coordinator unenforced (the default for detection-focused
    /// tests); the app injects a real gate.
    private let trustGate: TrustGate?

    public init(
        scanner: InventoryScanner,
        backend: any AdoptingBackend,
        catalog: CaskCatalog,
        scanDirectories: [String],
        trustGate: TrustGate? = nil
    ) {
        self.scanner = scanner
        self.backend = backend
        self.catalog = catalog
        self.scanDirectories = scanDirectories
        self.trustGate = trustGate
    }

    /// Scan, match and classify every installed app into an ``AppReport``.
    ///
    /// Works with Homebrew absent: `managedTokens()` returns empty, so nothing is
    /// flagged as already-managed and every other signal still resolves.
    public func makeReports() -> [AppReport] {
        let index = CaskIndex(casks: catalog.casks)
        let managed = backend.managedTokens()
        let resolver = MatchResolver(index: index, managedTokens: managed)

        let apps = scanner.scan(directories: scanDirectories)
        return apps.map { app in
            report(for: app, resolver: resolver, index: index, managedTokens: managed)
        }
    }

    /// Build a single report for `app` using a prepared resolver/index.
    private func report(
        for app: InstalledApp,
        resolver: MatchResolver,
        index: CaskIndex,
        managedTokens: Set<String>
    ) -> AppReport {
        let matches = resolver.matches(for: app)
        let eligibility = resolver.eligibility(for: app, matches: matches)
        let sources = detectSources(
            for: app, matches: matches, managedTokens: managedTokens
        )
        var prediction: AdoptionOutcomePrediction?
        if let token = eligibility.caskToken, let cask = index.cask(for: token) {
            prediction = resolver.predictOutcome(for: app, cask: cask)
        }
        return AppReport(
            app: app,
            matches: matches,
            eligibility: eligibility,
            sources: sources,
            predictedOutcome: prediction
        )
    }

    /// Derive the full set of update sources for an app. An app can legitimately
    /// belong to several at once, so this returns a set and never collapses a
    /// conflict.
    private func detectSources(
        for app: InstalledApp,
        matches: [AppMatch],
        managedTokens: Set<String>
    ) -> Set<AppSource> {
        var sources = Set<AppSource>()

        if app.hasMacAppStoreReceipt { sources.insert(.macAppStore) }
        if let feed = app.sparkleFeedURL { sources.insert(.sparkle(feedURL: feed)) }
        if app.hasSparkleFramework { sources.insert(.sparkleRuntime) }
        if app.isMicrosoftAutoUpdateManaged { sources.insert(.microsoftAutoUpdate) }
        if app.isAppleSoftwareUpdateManaged { sources.insert(.appleSoftwareUpdate) }

        for match in matches {
            sources.insert(
                .homebrew(
                    token: match.caskToken,
                    strength: match.strength,
                    managed: managedTokens.contains(match.caskToken)
                )
            )
        }
        return sources
    }

    // MARK: - Adoption

    /// Adopt `app`, then confirm the outcome with a fresh scan.
    ///
    /// Success is asserted **only** when the post-adopt rescan shows the app as
    /// Homebrew-managed. A backend "success" that the rescan does not corroborate
    /// is reported as ``AdoptionResult/notConfirmedByRescan`` — never as done.
    public func adopt(_ app: InstalledApp) -> AdoptionResult {
        adopt(app, acknowledgingTeamChange: false)
    }

    /// Adopt `app`, optionally acknowledging a team-ID change, then confirm with a
    /// rescan. The trust gate is consulted **before** the backend runs, so an
    /// unsigned/invalid/Gatekeeper-rejected bundle or an unacknowledged team-ID
    /// change is stopped while the app on disk is still untouched.
    public func adopt(_ app: InstalledApp, acknowledgingTeamChange: Bool) -> AdoptionResult {
        if let trustGate {
            let decision = trustGate.authorize(app, acknowledgeTeamChange: acknowledgingTeamChange)
            if let block = decision.block {
                return .blockedByTrust(block)
            }
        }

        let index = CaskIndex(casks: catalog.casks)
        let preManaged = backend.managedTokens()
        let resolver = MatchResolver(index: index, managedTokens: preManaged)

        let eligibility = resolver.eligibility(for: app)
        guard case let .eligible(token) = eligibility else {
            if case let .ineligible(reason) = eligibility {
                return .notEligible(reason: reason)
            }
            return .notEligible(reason: .noCaskMatch)
        }

        let action = backend.adopt(app: app, caskToken: token)

        switch action {
        case .caskError(let message):
            // Hard fail with a known cause; the app is untouched. Distinct from a
            // silent no-op precisely because the backend surfaced the CaskError.
            return .hardFailedWithCaskError(message: message)

        case .failed(let reason):
            return .failed(reason: reason)

        case .succeeded:
            // Trust nothing: re-scan inventory and re-query Homebrew, then
            // confirm the app is still present AND the cask now manages it.
            let postManaged = backend.managedTokens()
            let postResolver = MatchResolver(index: index, managedTokens: postManaged)
            let apps = scanner.scan(directories: scanDirectories)

            guard let rescanned = apps.first(where: { $0.bundlePath == app.bundlePath })
                ?? apps.first(where: { $0.bundleName == app.bundleName }) else {
                return .notConfirmedByRescan
            }

            // The decisive signal is that Homebrew now lists the adopted token;
            // a backend "success" the rescan does not corroborate is not done.
            guard postManaged.contains(token) else { return .notConfirmedByRescan }

            let report = report(
                for: rescanned,
                resolver: postResolver,
                index: index,
                managedTokens: postManaged
            )
            return .adopted(report)
        }
    }
}
