import Foundation

/// Turns an installed app plus a cask index into ranked matches, an adoption
/// eligibility verdict and an adoption outcome prediction.
///
/// This type carries the entire safety model of OpenFreshr, so its rules are
/// spelled out rather than clever:
///
/// 1. **Strong signal** — the app file name equals a cask moved-artifact target.
/// 2. **Veto** — a strong signal is revoked when the cask declares a bundle
///    identity — a strong field *or* a cleanup-path id — that belongs to a
///    *different organisation* than the installed bundle identifier. This is the
///    one mechanism that stops `Copilot.app` from being adopted as
///    `copilot-money`. A cask id that merely records this same app's *old*
///    identity across a rename (same reverse-DNS domain, or a final label that
///    still names the app) is not a contradiction and does not veto.
/// 3. **Weak signals** — a bundle identifier seen in a cask's stanzas, or a name
///    resemblance. Weak signals are suggestions and never authorise adoption.
/// 4. **Candidate filter** — adoption is offered only for an app with no Mac App
///    Store receipt, not already Homebrew-managed, whose cask ships a moved
///    artifact and survives as a strong, un-vetoed match.
public struct MatchResolver: Sendable {

    private let index: CaskIndex

    /// Cask tokens Homebrew already has installed (from `brew list --cask`).
    /// Empty when Homebrew is absent — matching still works, nothing is reported
    /// as already-managed.
    private let managedTokens: Set<String>

    public init(index: CaskIndex, managedTokens: Set<String> = []) {
        self.index = index
        self.managedTokens = managedTokens
    }

    // MARK: - Matching

    /// All candidate matches for `app`, each already carrying its effective
    /// strength (a vetoed strong match is demoted to weak with `vetoed == true`).
    public func matches(for app: InstalledApp) -> [AppMatch] {
        var matches: [AppMatch] = []
        var seenTokens = Set<String>()

        // 1. Strong signal: app file name == a moved-artifact target.
        let targetKey = app.bundleName.lowercased()
        for token in index.casksByAppTarget[targetKey] ?? [] {
            guard seenTokens.insert(token).inserted else { continue }
            let cask = index.cask(for: token)
            let vetoed = isVetoed(app: app, cask: cask)
            matches.append(
                AppMatch(
                    appBundlePath: app.bundlePath,
                    caskToken: token,
                    strength: vetoed ? .weak : .strong,
                    reason: .appArtifact(target: app.bundleName),
                    vetoed: vetoed
                )
            )
        }

        // 2. Weak signal: bundle identifier seen in the cask (primary or cleanup).
        if let bundleID = app.bundleIdentifier?.lowercased(), !bundleID.isEmpty {
            let tokens = (index.primaryIdentityTokens[bundleID] ?? [])
                + (index.cleanupIdentityTokens[bundleID] ?? [])
            for token in tokens {
                guard seenTokens.insert(token).inserted else { continue }
                matches.append(
                    AppMatch(
                        appBundlePath: app.bundlePath,
                        caskToken: token,
                        strength: .weak,
                        reason: .bundleIdentifierInStanza(identifier: app.bundleIdentifier ?? bundleID)
                    )
                )
            }
        }

        // 3. Weak signal: normalised name equality.
        let nameKey = CaskIndex.normalizeName(app.displayName)
        if !nameKey.isEmpty {
            for token in index.casksByNormalizedName[nameKey] ?? [] {
                guard seenTokens.insert(token).inserted else { continue }
                matches.append(
                    AppMatch(
                        appBundlePath: app.bundlePath,
                        caskToken: token,
                        strength: .weak,
                        reason: .nameSimilarity(caskName: token)
                    )
                )
            }
        }

        return matches
    }

    /// The veto rule.
    ///
    /// A strong artifact match is vetoed when the cask declares **any** bundle
    /// identity — primary (strong `quit`/`launchctl`/… fields) *or* path-derived
    /// cleanup ids — that belongs to a *different organisation* than the installed
    /// app: the cask is really about a foreign app that merely ships a file of the
    /// same name. Both buckets may raise a veto because a *contradiction* is a
    /// contradiction regardless of where the id was found (`copilot-money` names
    /// `com.copilot.production` only in a `trash` path, yet must still veto
    /// `com.microsoft.copilot-mac`).
    ///
    /// The premise "a non-matching id proves a *different app*" is false for a
    /// **rename of the same app**, and cask ids are frequently the pre-rename
    /// identity harvested from a cleanup path. So a literal non-membership is only
    /// a contradiction when *no* declared identity is plausibly this same app:
    ///
    /// * **Same organisation.** An id sharing the app's reverse-DNS domain — its
    ///   first two labels — is the same vendor (`raspberry-pi-imager` zaps
    ///   `com.raspberrypi.imagingutility`; the app is `com.raspberrypi.rpi-imager`
    ///   — renamed, same `com.raspberrypi`). Not a veto.
    /// * **Renamed across organisations.** An id whose final label still names the
    ///   app is the same app that also moved domains (`monitorcontrol` zaps
    ///   `me.guillaumeb.MonitorControl`; the app is now `app.monitorcontrol.*`).
    ///   Not a veto — the fail-closed gate downstream still withholds it unless it
    ///   is corroborated or version-checkable.
    ///
    /// A genuine third party — Microsoft Copilot (`com.microsoft.copilot-mac`)
    /// against `copilot-money`'s `com.copilot.production` — shares neither domain
    /// nor name, so it still vetoes. When the cask declares no identity at all the
    /// file name stands unopposed and the match is accepted (the common, safe
    /// case). When the app has no readable bundle identifier but the cask asserts
    /// an identity, the match is vetoed rather than trusted, because a silent
    /// wrong adoption is the worse failure — and without a domain there is nothing
    /// to recognise a rename by.
    private func isVetoed(app: InstalledApp, cask: Cask?) -> Bool {
        guard let cask else { return false }
        let identities = (cask.primaryBundleIdentifiers + cask.cleanupBundleIdentifiers)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard !identities.isEmpty else { return false }

        guard let bundleID = app.bundleIdentifier?.lowercased(), !bundleID.isEmpty else {
            return true
        }

        // The cask names this very app: never a contradiction.
        if identities.contains(bundleID) { return false }

        // Same-app rename guard: a shared organisational domain marks the same
        // vendor under a renamed id.
        if let appDomain = Self.organizationDomain(of: bundleID),
           identities.contains(where: { Self.organizationDomain(of: $0) == appDomain }) {
            return false
        }

        // Cross-organisation rename: a declared id whose final label still names
        // this app is its pre-rename identity, not a foreign one.
        let appNameKey = CaskIndex.normalizeName(app.displayName)
        if !appNameKey.isEmpty, identities.contains(where: { identity in
            let leaf = identity.split(separator: ".").last.map(String.init) ?? identity
            return CaskIndex.normalizeName(leaf) == appNameKey
        }) {
            return false
        }

        return true
    }

    /// The organisational domain of a reverse-DNS bundle identifier: its first two
    /// labels (e.g. `com.raspberrypi` for `com.raspberrypi.rpi-imager`). `nil` when
    /// the identifier carries fewer than two labels, so a bare token is never read
    /// as sharing an organisation with anything.
    static func organizationDomain(of bundleIdentifier: String) -> String? {
        let labels = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else { return nil }
        return labels.prefix(2).joined(separator: ".")
    }

    // MARK: - Eligibility

    /// Decide whether — and as which cask — `app` may be adopted.
    public func eligibility(for app: InstalledApp) -> AdoptionEligibility {
        eligibility(for: app, matches: matches(for: app))
    }

    /// Eligibility from a precomputed match list (so callers can reuse it).
    public func eligibility(for app: InstalledApp, matches: [AppMatch]) -> AdoptionEligibility {
        // A Mac App Store receipt means another manager already owns the app.
        if app.hasMacAppStoreReceipt {
            return .ineligible(reason: .managedByMacAppStore)
        }

        let strongMatches = matches.filter { $0.strength == .strong }

        // Candidates: strong matches whose cask is not already managing the app
        // and ships a moved artifact (true by construction for a strong match).
        let adoptable = strongMatches.filter { match in
            guard !managedTokens.contains(match.caskToken) else { return false }
            guard let cask = index.cask(for: match.caskToken) else { return false }
            return cask.shipsMovedArtifact && !cask.isInstallerOnly
        }

        // Fail-closed gate. A strong artifact match is only trustworthy enough to
        // offer when it is **positively corroborated** (the installed bundle
        // identifier appears in the cask's identity) OR the cask does not
        // auto-update — in which case Homebrew's own version check would abort a
        // wrong adopt with a `CaskError`. An auto-updating cask skips that check,
        // so an uncorroborated match there could silently swap the user's app.
        let corroboratedOrCheckable = adoptable.filter { match in
            guard let cask = index.cask(for: match.caskToken) else { return false }
            return isCorroborated(app: app, cask: cask) || cask.autoUpdates == false
        }

        if let best = preferredCandidate(from: corroboratedOrCheckable, app: app) {
            return .eligible(caskToken: best.caskToken)
        }

        // A strong, otherwise-adoptable match existed but its identity could not
        // be confirmed and the cask auto-updates. Refuse it explicitly — this is
        // what blocks Copilot even when the cask carries no identity at all.
        if let unconfirmed = preferredCandidate(from: adoptable, app: app) {
            return .ineligible(reason: .identityNotConfirmed(caskToken: unconfirmed.caskToken))
        }

        // A strong match existed but every candidate cask is already managing it.
        if let managed = strongMatches.first(where: { managedTokens.contains($0.caskToken) }) {
            return .ineligible(reason: .alreadyHomebrewManaged(caskToken: managed.caskToken))
        }

        // No strong candidate survived. Explain the most specific reason.
        if let vetoed = matches.first(where: { $0.vetoed }) {
            return .ineligible(reason: .strongMatchVetoed(caskToken: vetoed.caskToken))
        }

        if let installerOnly = matches.first(where: { match in
            index.cask(for: match.caskToken)?.isInstallerOnly == true
        }) {
            return .ineligible(reason: .caskIsInstallerOnly(caskToken: installerOnly.caskToken))
        }

        if matches.isEmpty {
            return .ineligible(reason: .noCaskMatch)
        }
        return .ineligible(reason: .onlyWeakMatches)
    }

    /// Choose among strong candidates: a cask whose primary identity actually
    /// contains the app's bundle identifier wins over one that merely shares a
    /// file name; otherwise the first (stable, sorted) candidate is taken.
    private func preferredCandidate(from candidates: [AppMatch], app: InstalledApp) -> AppMatch? {
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { $0.caskToken < $1.caskToken }
        if let corroborated = sorted.first(where: { match in
            guard let cask = index.cask(for: match.caskToken) else { return false }
            return isCorroborated(app: app, cask: cask)
        }) {
            return corroborated
        }
        return sorted.first
    }

    /// `true` when the cask positively confirms it is about this installed app.
    ///
    /// Proof comes from the **strong** identity bucket: the app's bundle
    /// identifier appears in `primaryBundleIdentifiers`. Only when a cask declares
    /// *no* strong identity at all may the path-derived `cleanupBundleIdentifiers`
    /// stand in as a fallback — a cask that does declare strong fields is taken at
    /// its word and a stray cleanup-path id must not corroborate it. This is the
    /// separation that stops a `trash` path from forging a corroboration while
    /// still recovering identity for the many casks (VLC, Obsidian, …) that ship
    /// nothing but a `zap` path.
    private func isCorroborated(app: InstalledApp, cask: Cask) -> Bool {
        guard let bundleID = app.bundleIdentifier?.lowercased(), !bundleID.isEmpty else {
            return false
        }
        if cask.primaryBundleIdentifiers.contains(where: { $0.lowercased() == bundleID }) {
            return true
        }
        // Fallback only when the cask declares no strong identity whatsoever.
        guard cask.primaryBundleIdentifiers.isEmpty else { return false }
        return cask.cleanupBundleIdentifiers.contains { $0.lowercased() == bundleID }
    }

    // MARK: - Outcome prediction

    /// Predict what Homebrew's `--adopt` would do for `app` as `cask`.
    ///
    /// Advisory only: the coordinator confirms real success with a rescan. The
    /// prediction mirrors the verified adopt semantics — an auto-updating cask
    /// skips the version check and succeeds unconditionally; otherwise matching
    /// versions succeed and differing versions abort with a `CaskError`.
    public func predictOutcome(for app: InstalledApp, cask: Cask) -> AdoptionOutcomePrediction {
        if cask.autoUpdates {
            return .succeedsUnconditionally
        }
        guard let caskVersion = cask.version, !caskVersion.isEmpty else {
            return .unknown
        }
        let appVersions = [app.shortVersion, app.bundleVersion].compactMap { version -> String? in
            guard let version, !version.isEmpty else { return nil }
            return version
        }
        guard !appVersions.isEmpty else { return .unknown }
        return appVersions.contains(caskVersion) ? .succeeds : .abortsWithCaskError
    }
}
