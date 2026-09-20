import Foundation

/// Why an app cannot be adopted into Homebrew management.
///
/// These are the concrete gates from the phase 1 candidate filter. Keeping them
/// as distinct cases (rather than a bool) lets the UI explain *why* an app is not
/// offered, and lets the regression tests assert the exact reason a dangerous
/// match was rejected.
public enum IneligibilityReason: Hashable, Sendable, Codable {

    /// No cask matched the app at all.
    case noCaskMatch

    /// Only weak matches exist (bundle-id/name); none strong enough to adopt.
    case onlyWeakMatches

    /// A strong artifact match was vetoed because the app's bundle identifier
    /// contradicts the cask's primary identity. This is the case that blocks
    /// `Copilot` from being adopted as `copilot-money`.
    case strongMatchVetoed(caskToken: String)

    /// The matched cask installs via `pkg`/`installer` and ships no moved
    /// artifact, so adoption would not be lossless.
    case caskIsInstallerOnly(caskToken: String)

    /// A strong artifact match exists and the cask would adopt losslessly, but
    /// the app's identity could **not be positively confirmed** (its bundle
    /// identifier is absent from the cask's identity) *and* the cask
    /// `auto_updates`, so Homebrew's own version check would not catch a wrong
    /// match either. Fail closed: refuse rather than risk swapping the app.
    case identityNotConfirmed(caskToken: String)

    /// The app carries a Mac App Store receipt; another manager already owns it.
    case managedByMacAppStore

    /// The app is already managed by an installed Homebrew cask.
    case alreadyHomebrewManaged(caskToken: String)

    /// Human explanation for the UI.
    public var explanation: String {
        switch self {
        case .noCaskMatch:
            return "Kein passendes Cask gefunden"
        case .onlyWeakMatches:
            return "Nur schwache Treffer (Bundle-ID/Name) — kein sicherer Kandidat"
        case let .strongMatchVetoed(token):
            return "Artefakt-Treffer \(token) durch Veto entwertet (Bundle-ID widerspricht der Cask-Identität)"
        case let .caskIsInstallerOnly(token):
            return "Cask \(token) installiert per pkg/installer — nicht verlustfrei adoptierbar"
        case let .identityNotConfirmed(token):
            return "Identität nicht bestätigt: Bundle-ID nicht in der Cask-Identität von \(token) und Cask aktualisiert sich selbst — Adoption zu riskant"
        case .managedByMacAppStore:
            return "Wird bereits über den Mac App Store verwaltet"
        case let .alreadyHomebrewManaged(token):
            return "Wird bereits von Homebrew (\(token)) verwaltet"
        }
    }
}

/// Result of the adoption candidate filter for one app.
///
/// `eligible` carries the single cask token that may be adopted; the filter only
/// ever yields a candidate when exactly one strong, un-vetoed, moved-artifact,
/// non-MAS, not-yet-managed match remains.
public enum AdoptionEligibility: Hashable, Sendable, Codable {
    case eligible(caskToken: String)
    case ineligible(reason: IneligibilityReason)

    /// The adoptable cask token, or `nil` when ineligible.
    public var caskToken: String? {
        switch self {
        case let .eligible(token): return token
        case .ineligible: return nil
        }
    }

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

/// What Homebrew's `--adopt` is expected to do for a candidate, derived from the
/// cask's `auto_updates` flag and the version comparison.
///
/// This prediction is advisory — it lets the UI warn the user before they act —
/// but the coordinator never trusts it as proof. Real success is only ever
/// confirmed by a rescan.
public enum AdoptionOutcomePrediction: Hashable, Sendable, Codable {

    /// `auto_updates true`: the version check is skipped, adoption is expected to
    /// succeed unconditionally.
    case succeedsUnconditionally

    /// Versions match (or the cask has none to compare): adoption is expected to
    /// succeed.
    case succeeds

    /// `auto_updates false` and the versions differ: Homebrew is expected to
    /// abort with a `CaskError`, leaving the app untouched.
    case abortsWithCaskError

    /// Not enough information (missing versions on a non-auto-updating cask).
    case unknown

    public var explanation: String {
        switch self {
        case .succeedsUnconditionally:
            return "auto_updates: Adoption gelingt bedingungslos (Versionscheck übersprungen)"
        case .succeeds:
            return "Versionen passen — Adoption sollte gelingen"
        case .abortsWithCaskError:
            return "Versionen weichen ab — Homebrew bricht mit CaskError ab, App bleibt unangetastet"
        case .unknown:
            return "Ausgang unklar (Versionsangaben fehlen)"
        }
    }
}
