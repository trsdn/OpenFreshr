import Foundation

/// The outcome of one attempted update, confirmed (or not) by a rescan.
///
/// Mirrors ``AdoptionResult`` but for updates. The decisive case is
/// ``updated``: it is reported **only** when a fresh scan no longer sees the
/// update, never on the backend's word alone. Every case carries its
/// ``UpdateItem`` so a batch can retry exactly the ones that did not land.
public enum UpdateOutcome: Sendable {
    /// The backend reported success **and** a rescan confirms the update is gone.
    case updated(UpdateItem)
    /// The backend reported success but the rescan still sees the update. Not done.
    case notConfirmedByRescan(UpdateItem)
    /// A cask-level hard fail with a known cause; the app is untouched.
    case caskError(UpdateItem, message: String)
    /// Any other failure (tool missing, non-zero exit, launch failure).
    case failed(UpdateItem, reason: BackendFailureReason)

    public var item: UpdateItem {
        switch self {
        case let .updated(item),
             let .notConfirmedByRescan(item),
             let .caskError(item, _),
             let .failed(item, _):
            return item
        }
    }

    public var didUpdate: Bool {
        if case .updated = self { return true }
        return false
    }

    /// Whether offering a retry makes sense (everything but a confirmed update).
    public var isRetryable: Bool { !didUpdate }
}

/// The result of running a whole ``UpdateRelease``.
///
/// Each item is executed and confirmed independently, so one app's failure can
/// never turn into another app's false success. ``retryRelease()`` bundles only
/// the items that did not land, honouring the "retry just the failures" rule.
public struct UpdateBatchResult: Sendable {

    public let outcomes: [UpdateOutcome]

    public init(outcomes: [UpdateOutcome]) {
        self.outcomes = outcomes
    }

    /// Items whose update was confirmed by a rescan.
    public var updatedItems: [UpdateItem] { outcomes.filter { $0.didUpdate }.map { $0.item } }

    /// Items that failed or were not confirmed, and could be retried.
    public var retryableItems: [UpdateItem] { outcomes.filter { $0.isRetryable }.map { $0.item } }

    public var allSucceeded: Bool { outcomes.allSatisfy { $0.didUpdate } }

    /// A release containing only the retryable items, preserving the release
    /// invariant (never mixes major with regular). `nil` when nothing remains.
    public func retryRelease() -> UpdateRelease? {
        UpdateRelease(items: retryableItems)
    }
}

/// Owns the phase 2/3 sequence **scan → detect (per source) → update →
/// rescan → confirm**, the update-side analogue of ``AdoptionCoordinator``.
///
/// It lives in the core so the whole flow — version comparison, feed and tool
/// probing, batch execution, rescan confirmation — is exercised through fakes,
/// never SwiftUI. Every fact it gathers degrades independently: a missing tool,
/// an unreachable feed or an unreadable version turns *its* source `unbekannt`
/// and leaves the rest of the app's sources intact.
public struct UpdateCoordinator: Sendable {

    private let scanner: any Scanning
    private let homebrew: HomebrewBackend
    private let macAppStore: MacAppStoreBackend
    private let microsoftAutoUpdate: MicrosoftAutoUpdateBackend
    private let catalog: CaskCatalog
    private let httpFetcher: any HTTPFetching
    private let scanDirectories: [String]

    public init(
        scanner: any Scanning,
        homebrew: HomebrewBackend,
        macAppStore: MacAppStoreBackend,
        microsoftAutoUpdate: MicrosoftAutoUpdateBackend,
        catalog: CaskCatalog,
        httpFetcher: any HTTPFetching,
        scanDirectories: [String]
    ) {
        self.scanner = scanner
        self.homebrew = homebrew
        self.macAppStore = macAppStore
        self.microsoftAutoUpdate = microsoftAutoUpdate
        self.catalog = catalog
        self.httpFetcher = httpFetcher
        self.scanDirectories = scanDirectories
    }

    // MARK: - Detection

    /// Scan, probe every source and classify each app into an ``AppUpdateReport``.
    public func makeUpdateReports() async -> [AppUpdateReport] {
        let apps = scanner.scan(directories: scanDirectories)
        let facts = await gatherFacts(for: apps)
        return apps.map { report(for: $0, facts: facts) }
    }

    /// The environment facts a batch of reports is built from, gathered once.
    private struct Facts: Sendable {
        var index: CaskIndex
        var resolver: MatchResolver
        var managedTokens: Set<String>
        var receiptVersions: [String: String]
        var masOutdated: [MasOutdatedEntry]?
        var mauList: [MsupdateAppEntry]?
        var sparkle: [String: SparkleOutcome]
    }

    /// What a Sparkle feed probe produced for one app.
    private enum SparkleOutcome: Sendable {
        case unreachable
        case unparsable
        case version(String)
    }

    /// Gather every fact once: Homebrew catalog/managed state (pure + one `brew
    /// list`), a single `mas outdated`, a single `msupdate --list`, and the
    /// Sparkle feeds fetched concurrently — only for apps that actually carry one.
    private func gatherFacts(for apps: [InstalledApp]) async -> Facts {
        let index = CaskIndex(casks: catalog.casks)
        let managed = homebrew.managedTokens()
        let receiptVersions = homebrew.managedReceiptVersions()
        let resolver = MatchResolver(index: index, managedTokens: managed)
        let masOutdated = macAppStore.isAvailable() ? macAppStore.outdated() : nil
        let mauList = microsoftAutoUpdate.isAvailable() ? microsoftAutoUpdate.list() : nil
        let sparkle = await fetchSparkleOutcomes(for: apps)
        return Facts(
            index: index,
            resolver: resolver,
            managedTokens: managed,
            receiptVersions: receiptVersions,
            masOutdated: masOutdated,
            mauList: mauList,
            sparkle: sparkle
        )
    }

    /// Fetch every Sparkle feed concurrently, distinguishing "could not reach"
    /// from "reached but no usable version" so the UI can say which.
    private func fetchSparkleOutcomes(for apps: [InstalledApp]) async -> [String: SparkleOutcome] {
        let feeds: [(bundlePath: String, feed: String)] = apps.compactMap { app in
            guard let feed = app.sparkleFeedURL, !feed.isEmpty else { return nil }
            return (app.bundlePath, feed)
        }
        guard !feeds.isEmpty else { return [:] }

        let fetcher = httpFetcher
        return await withTaskGroup(of: (String, SparkleOutcome).self) { group in
            for entry in feeds {
                group.addTask {
                    (entry.bundlePath, await Self.probeFeed(entry.feed, using: fetcher))
                }
            }
            var outcomes: [String: SparkleOutcome] = [:]
            for await (bundlePath, outcome) in group {
                outcomes[bundlePath] = outcome
            }
            return outcomes
        }
    }

    /// Probe a single feed: transport failure → `.unreachable`; fetched but no
    /// version → `.unparsable`; otherwise the newest advertised version.
    private static func probeFeed(_ feed: String, using fetcher: any HTTPFetching) async -> SparkleOutcome {
        guard let url = URL(string: feed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return .unreachable
        }
        guard let data = try? await fetcher.data(from: url) else { return .unreachable }
        guard let version = SparkleAppcast.newestVersion(from: data) else { return .unparsable }
        return .version(version)
    }

    /// Build the full per-source report for one app from the gathered facts.
    private func report(for app: InstalledApp, facts: Facts) -> AppUpdateReport {
        var sources: [SourceUpdate] = []

        if let homebrew = homebrewSource(for: app, facts: facts) { sources.append(homebrew) }
        if let mas = macAppStoreSource(for: app, facts: facts) { sources.append(mas) }
        if let mau = microsoftAutoUpdateSource(for: app, facts: facts) { sources.append(mau) }
        if let sparkle = sparkleSource(for: app, facts: facts) { sources.append(sparkle) }

        let isSelfUpdating = app.hasSparkleFramework || app.isElectron || app.sparkleFeedURL != nil
        return AppUpdateReport(app: app, sources: sources, isSelfUpdating: isSelfUpdating)
    }

    // MARK: - Per-source detection

    /// The Homebrew source, emitted for a **confident** cask association. Three
    /// cases, kept strictly apart because conflating them is exactly what breaks
    /// real apps:
    ///
    /// * The token is one Homebrew **manages** (`brew list --cask`): a real
    ///   `brew upgrade` can act on it, so this is the *only* path that may carry
    ///   an executable ``SourceUpdate/command``. Within it, one further split:
    ///   an ordinary **backlog** (the receipt is behind the cask) upgrades, but a
    ///   **receipt drift** (the receipt has already reached the cask version while
    ///   the app on disk is older — the `auto_updates` blind spot) makes
    ///   `brew upgrade` a silent no-op, so it is driven with `brew reinstall`
    ///   instead. The disk version stays the sole authority on *whether* an update
    ///   is due; the receipt only picks *which verb* lands it.
    /// * The token is merely **adoptable** — the fail-closed eligibility gate
    ///   would adopt it — but not yet managed, **and a real update is due**. The
    ///   two former steps (adopt, then update) are merged into one drivable action:
    ///   the source carries a two-command ``SourceUpdate/commandPlan`` — take the
    ///   app over with `brew install --cask --adopt`, then land the disk version
    ///   with `brew reinstall --cask` (after an adopt the receipt sits on the cask
    ///   version while the disk still holds the old app — exactly the drift shape).
    ///   The adoption guard has not vanished; it moved one level down (the adopt
    ///   step must succeed before the reinstall runs). Unless the take-over is
    ///   **predicted to abort** (``AdoptionOutcomePrediction/abortsWithCaskError`` —
    ///   a non-auto-updating cask whose installed version differs): then there is
    ///   no clean Homebrew path, so the source is left non-drivable with an
    ///   ``UpdateActionBlocker/adoptionWouldFail`` marker instead of running the
    ///   user into a failure.
    ///
    /// Anything less than a confident association is skipped rather than risk a
    /// wrong-cask comparison producing a phantom update.
    private func homebrewSource(for app: InstalledApp, facts: Facts) -> SourceUpdate? {
        let matches = facts.resolver.matches(for: app)

        // Managed → the single path allowed to produce an executable upgrade.
        if let managedToken = matches.first(where: { facts.managedTokens.contains($0.caskToken) })?.caskToken,
           let cask = facts.index.cask(for: managedToken) {
            // Disk is always the authority on whether an update is due. When one
            // is, decide *which* brew verb actually lands it: an ordinary backlog
            // upgrades, but a receipt that has already reached the cask version
            // while the disk lags behind is drift — `brew upgrade` would no-op, so
            // reinstall instead.
            let state = UpdateResolver.state(installed: app.displayVersion, available: cask.version)
            let strategy: HomebrewUpdateStrategy? = state.hasUpdate
                ? (Self.isReceiptDrift(token: managedToken, caskVersion: cask.version, facts: facts)
                    ? .reinstall : .upgrade)
                : nil
            let command = strategy.flatMap {
                homebrew.resolveUpdateCommand(identifier: managedToken, strategy: $0)
            }
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .homebrew(token: managedToken),
                state: state,
                command: command,
                homebrewStrategy: strategy
            )
        }

        // Adoptable but not managed. When a real update is due, merge adoption and
        // update into one drivable action; otherwise report the plain state (a
        // pure take-over without an update stays a secondary action elsewhere).
        guard case let .eligible(eligibleToken) = facts.resolver.eligibility(for: app, matches: matches),
              let cask = facts.index.cask(for: eligibleToken) else {
            return nil
        }
        let state = UpdateResolver.state(installed: app.displayVersion, available: cask.version)
        guard state.hasUpdate else {
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .homebrew(token: eligibleToken),
                state: state
            )
        }

        // A real update on an adoptable-but-unmanaged cask. Predict whether the
        // `--adopt` take-over would succeed. If so, the app is drivable in two
        // steps (adopt, then the receipt-drift reinstall that lands the disk
        // version). If the take-over is predicted to abort with a CaskError — a
        // non-auto-updating cask whose installed version differs — there is no
        // clean Homebrew path, so surface it honestly instead of running into the
        // failure. `.unknown` cannot co-occur with `state.hasUpdate` (both
        // versions are present here), but is treated as non-drivable defensively.
        switch facts.resolver.predictOutcome(for: app, cask: cask) {
        case .succeedsUnconditionally, .succeeds:
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .homebrew(token: eligibleToken),
                state: state,
                homebrewStrategy: .adoptThenReinstall,
                commandPlan: homebrew.resolveCommandPlan(
                    identifier: eligibleToken, strategy: .adoptThenReinstall) ?? []
            )
        case .abortsWithCaskError, .unknown:
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .homebrew(token: eligibleToken),
                state: state,
                actionBlocker: .adoptionWouldFail(caskToken: eligibleToken)
            )
        }
    }

    /// Whether a managed cask is in **receipt drift**: Homebrew's receipt version
    /// has already reached (or passed) the cask version. Only a *confident*
    /// "receipt ≥ cask" counts — an absent or incomparable receipt yields `false`,
    /// so a reinstall is chosen only when certain, exactly as the "im Zweifel
    /// nicht handeln" rule requires. The complementary "disk is behind the cask"
    /// half is the caller's `state.hasUpdate`, itself the authoritative
    /// disk-vs-cask comparison — so the two together mean *receipt caught up, disk
    /// did not*, which is precisely when `brew upgrade` no-ops and `reinstall` is
    /// the only verb that lands the update. The LibreOffice shape (receipt
    /// `26.8.0`, disk `26.8.0.3`) never reaches here: the disk is *newer* than the
    /// cask, so `state.hasUpdate` is already false and no action is taken.
    private static func isReceiptDrift(token: String, caskVersion: String?, facts: Facts) -> Bool {
        guard let caskVersion,
              let receipt = facts.receiptVersions[token],
              let order = VersionComparator.compare(installed: receipt, available: caskVersion) else {
            return false
        }
        return order == .same || order == .newer
    }

    /// The Mac App Store source for any app carrying a store receipt. `mas` is
    /// authoritative here: an app it lists as outdated is an update (target =
    /// the version `mas` names); a receipt app it does not list is up to date;
    /// and a missing `mas` degrades the source to `unbekannt`.
    private func macAppStoreSource(for app: InstalledApp, facts: Facts) -> SourceUpdate? {
        guard app.hasMacAppStoreReceipt else { return nil }

        guard let outdated = facts.masOutdated else {
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .macAppStore(appID: ""),
                state: .unknown(.toolUnavailable)
            )
        }

        guard let entry = outdated.first(where: { Self.namesMatch($0.name, app) }) else {
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .macAppStore(appID: ""),
                state: .upToDate
            )
        }

        let isMajor = VersionComparator.isMajorChange(
            from: app.displayVersion ?? entry.installedVersion,
            to: entry.availableVersion
        )
        let command = macAppStore.resolveUpdateCommand(identifier: entry.identifier)
        return SourceUpdate(
            appBundlePath: app.bundlePath,
            kind: .macAppStore(appID: entry.identifier),
            state: .updateAvailable(available: entry.availableVersion, isMajor: isMajor),
            command: command
        )
    }

    /// The Microsoft AutoUpdate source for any `com.microsoft.` app. A missing
    /// `msupdate` degrades to `unbekannt`; an app MAU does not list is up to
    /// date; a listed app becomes an update only when its version parses and
    /// compares strictly newer — otherwise it stays `unbekannt` (never a guess).
    private func microsoftAutoUpdateSource(for app: InstalledApp, facts: Facts) -> SourceUpdate? {
        guard app.isMicrosoftAutoUpdateManaged else { return nil }

        guard let list = facts.mauList else {
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .microsoftAutoUpdate(appID: ""),
                state: .unknown(.toolUnavailable)
            )
        }

        guard let entry = list.first(where: { Self.namesMatch($0.title, app) }) else {
            return SourceUpdate(
                appBundlePath: app.bundlePath,
                kind: .microsoftAutoUpdate(appID: ""),
                state: .upToDate
            )
        }

        let state = UpdateResolver.state(installed: app.displayVersion, available: entry.availableVersion)
        let command = state.hasUpdate ? microsoftAutoUpdate.resolveUpdateCommand(identifier: entry.appID) : nil
        return SourceUpdate(
            appBundlePath: app.bundlePath,
            kind: .microsoftAutoUpdate(appID: entry.appID),
            state: state,
            command: command
        )
    }

    /// The Sparkle source, present only when the app advertises a feed. It never
    /// carries a command: a Sparkle app updates itself, and OpenFreshr must not
    /// drive a second updater against it. The feed outcome maps straight to a
    /// state, defaulting to `unbekannt` on any doubt.
    private func sparkleSource(for app: InstalledApp, facts: Facts) -> SourceUpdate? {
        guard let feed = app.sparkleFeedURL, !feed.isEmpty else { return nil }

        let state: UpdateState
        switch facts.sparkle[app.bundlePath] {
        case .version(let version):
            state = UpdateResolver.state(installed: app.displayVersion, available: version)
        case .unparsable:
            state = .unknown(.feedUnparsable)
        case .unreachable, nil:
            state = .unknown(.feedUnreachable)
        }
        return SourceUpdate(
            appBundlePath: app.bundlePath,
            kind: .sparkle(feedURL: feed),
            state: state,
            command: nil
        )
    }

    // MARK: - Execution

    /// Run every item in `release`, each isolated and each confirmed by a rescan.
    ///
    /// Isolation is total: an item's failure is captured in its own
    /// ``UpdateOutcome`` and never propagates, so one broken update can never
    /// mark another app as done. Success is asserted **only** when a fresh scan
    /// no longer reports the update.
    public func perform(_ release: UpdateRelease) async -> UpdateBatchResult {
        var outcomes: [UpdateOutcome] = []
        for item in release.items {
            outcomes.append(perform(item))
        }
        return UpdateBatchResult(outcomes: outcomes)
    }

    /// Run and confirm a single item.
    public func perform(_ item: UpdateItem) -> UpdateOutcome {
        guard let identifier = item.sourceKind.identifier, !identifier.isEmpty else {
            return .failed(item, reason: .invalidIdentifier(""))
        }

        // Homebrew items split by strategy at the execution site:
        //
        // * `.adoptThenReinstall` — the merged take-over for an adoptable-but-
        //   unmanaged app. Step 1 adopts the app; **only on its success** does
        //   step 2 (`reinstall`) run to land the disk version. The old "this app
        //   may not be updated" guard did not vanish — it moved *into* this action
        //   as "the take-over must have succeeded before the upgrade". A failed
        //   adopt is attributed to this app (a version-mismatch reported as a
        //   `CaskError`) and step 2 is skipped.
        //
        // * `.upgrade` / `.reinstall` — a managed cask, driven directly. The
        //   standing safety net stays: never run `brew upgrade`/`reinstall`
        //   against a cask Homebrew does not manage (the Amazon-Photos trap), so
        //   an unmanaged token is refused *here*, before it can reach the backend.
        //   The item's own strategy is used verbatim so a drift item reinstalls
        //   rather than falling back to the no-op `upgrade`.
        //
        // Because a single update, a batch (which calls this per item) and the
        // major-upgrade path all run through this one method, these checks cover
        // every route — and the confirm-by-rescan contract is untouched, since a
        // refused item never claims success and step 2 is the only thing a rescan
        // ever confirms.
        if case let .homebrew(token) = item.sourceKind {
            switch item.homebrewStrategy {
            case .adoptThenReinstall:
                let adopted = homebrew.adopt(app: item.app, caskToken: token)
                guard adopted.didReportSuccess else {
                    // Step 2 is skipped; report the adopt failure as-is (a
                    // version-mismatch surfaces as `.caskError`).
                    return classify(adopted, for: item)
                }
                return classify(homebrew.update(identifier: token, strategy: .reinstall), for: item)
            case .upgrade, .reinstall:
                guard homebrew.managedTokens().contains(token) else {
                    return .failed(item, reason: .requiresAdoption(caskToken: token))
                }
                return classify(homebrew.update(identifier: token, strategy: item.homebrewStrategy), for: item)
            }
        }

        return classify(backend(for: item.backend).update(identifier: identifier), for: item)
    }

    /// Turn a backend's claimed result into a confirmed outcome. Success is
    /// asserted **only** when a fresh rescan no longer sees the update; a
    /// `CaskError` and any other failure are reported as-is. Shared by every
    /// backend route so the confirm-by-rescan contract has a single home.
    private func classify(_ result: BackendActionResult, for item: UpdateItem) -> UpdateOutcome {
        switch result {
        case .succeeded:
            return reconfirm(item) ? .updated(item) : .notConfirmedByRescan(item)
        case let .caskError(message):
            return .caskError(item, message: message)
        case let .failed(reason):
            return .failed(item, reason: reason)
        }
    }

    /// The backend that drives a given kind.
    private func backend(for kind: UpdateBackendKind) -> any PackageBackend {
        switch kind {
        case .homebrew: return homebrew
        case .macAppStore: return macAppStore
        case .microsoftAutoUpdate: return microsoftAutoUpdate
        }
    }

    /// Re-scan and re-detect just this item's source; `true` only when the update
    /// is no longer offered. Trusts data, never the backend's success claim.
    private func reconfirm(_ item: UpdateItem) -> Bool {
        let apps = scanner.scan(directories: scanDirectories)
        guard let app = apps.first(where: { $0.bundlePath == item.app.bundlePath })
            ?? apps.first(where: { $0.bundleName == item.app.bundleName }) else {
            return false
        }

        switch item.backend {
        case .homebrew:
            guard case let .homebrew(token) = item.sourceKind else { return false }
            let index = CaskIndex(casks: catalog.casks)
            guard let cask = index.cask(for: token) else { return false }
            let state = UpdateResolver.state(installed: app.displayVersion, available: cask.version)
            return !state.hasUpdate

        case .macAppStore:
            guard case let .macAppStore(appID) = item.sourceKind else { return false }
            // A degraded `mas` cannot confirm anything; refuse to claim success.
            guard let outdated = macAppStore.outdated() else { return false }
            return !outdated.contains { $0.identifier == appID }

        case .microsoftAutoUpdate:
            guard case let .microsoftAutoUpdate(appID) = item.sourceKind else { return false }
            guard let list = microsoftAutoUpdate.list() else { return false }
            return !list.contains { $0.appID == appID }
        }
    }

    // MARK: - Item construction

    /// Build the drivable ``UpdateItem`` for a report's source, or `nil` when the
    /// source is not a drivable update. The single place the UI turns a detected
    /// source into a unit of work.
    public static func updateItem(for report: AppUpdateReport, source: SourceUpdate) -> UpdateItem? {
        guard source.isDrivable,
              let backend = source.backend,
              let command = source.command,
              case let .updateAvailable(available, isMajor) = source.state else {
            return nil
        }
        return UpdateItem(
            app: report.app,
            sourceKind: source.kind,
            backend: backend,
            command: command,
            targetVersion: available,
            isMajor: isMajor,
            homebrewStrategy: source.homebrewStrategy ?? .upgrade,
            commandPlan: source.commandPlan
        )
    }

    // MARK: - Name matching

    /// Loose name match between a tool's app name and an installed bundle:
    /// normalised equality first, then either-way containment for prefixes like
    /// "Microsoft ". Conservative by design — a non-match simply means the tool's
    /// entry is not linked to this app, which degrades to `unbekannt`/up-to-date
    /// rather than to a wrong action.
    static func namesMatch(_ toolName: String, _ app: InstalledApp) -> Bool {
        let candidates = [app.displayName, app.bundleName].map(normalize)
        let target = normalize(toolName)
        guard !target.isEmpty else { return false }
        for candidate in candidates where !candidate.isEmpty {
            if candidate == target { return true }
            if candidate.contains(target) || target.contains(candidate) { return true }
        }
        return false
    }

    private static func normalize(_ name: String) -> String {
        var value = name.lowercased()
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        let allowed = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(allowed))
    }
}
