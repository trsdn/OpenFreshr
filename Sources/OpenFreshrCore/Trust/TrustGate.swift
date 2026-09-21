import Foundation

/// A concrete, observed change of the signing team for one bundle.
public struct TeamIdentifierChange: Sendable, Hashable {
    public var bundleIdentifier: String
    public var previousTeamIdentifier: String
    public var newTeamIdentifier: String

    public init(bundleIdentifier: String, previousTeamIdentifier: String, newTeamIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.previousTeamIdentifier = previousTeamIdentifier
        self.newTeamIdentifier = newTeamIdentifier
    }
}

/// A check that could not be completed, so the gate proceeded **without** being
/// able to assert safety. Surfaced so the UI can say "not verified" instead of
/// implying a clean bill of health.
public enum TrustDegradation: Sendable, Hashable {
    /// `codesign` was unavailable, so the signature could not be verified at all.
    case signatureToolUnavailable
    /// A baseline exists but the current team ID could not be read, so the
    /// team-change comparison could not run.
    case teamIdentifierUnreadable
}

/// Why the gate refused an automatic replacement.
public enum TrustBlock: Sendable, Hashable {
    case unsigned
    case signatureInvalid(String)
    case gatekeeperRejected(String)
    case identityUnreadable
    case teamIdentifierChanged(TeamIdentifierChange)

    /// A user-facing explanation for the confirmation dialog / status.
    public var explanation: String {
        switch self {
        case .unsigned:
            return String(localized: "The app bundle is not signed. OpenFreshr does not replace an unsigned app automatically.")
        case let .signatureInvalid(message):
            return String(localized: "The signature check failed (\(message)). The replacement is blocked.")
        case let .gatekeeperRejected(message):
            return String(localized: "Gatekeeper rejected the bundle (\(message)). The replacement is blocked.")
        case .identityUnreadable:
            return String(localized: "The bundle identity is unreadable. Without a clear identity nothing is replaced automatically — please check manually.")
        case let .teamIdentifierChanged(change):
            return String(localized: "The team ID changed (was \(change.previousTeamIdentifier), now \(change.newTeamIdentifier), bundle \(change.bundleIdentifier)). This can be a legitimate takeover by the vendor — or a takeover of the update channel. Requires your explicit confirmation.")
        }
    }
}

/// The gate's decision for a single, about-to-happen replacement.
public enum TrustDecision: Sendable, Hashable {
    /// Proceed: the signature verified and the team ID matches (or first-use just
    /// established the baseline, or a change was explicitly acknowledged).
    case allowed
    /// Proceed, but a check could not run (a signing tool was missing). No
    /// security is asserted; the caller/UI should say so.
    case allowedWithoutVerification(TrustDegradation)
    /// Do not proceed. Carries the reason for the block.
    case blocked(TrustBlock)

    public var isAllowed: Bool {
        switch self {
        case .allowed, .allowedWithoutVerification: return true
        case .blocked: return false
        }
    }

    public var block: TrustBlock? {
        if case let .blocked(block) = self { return block }
        return nil
    }
}

/// The read-only trust picture for one app, for display in the UI. Computed
/// without mutating the store, so simply *looking* at an app never records a
/// baseline — only an actual replacement does.
public struct TrustEvaluation: Sendable, Hashable {
    /// The normalised bundle identifier used as the trust key, if readable.
    public var bundleIdentifier: String?
    /// The raw signing facts (team ID, verification, Gatekeeper) for direct display.
    public var signature: CodeSignatureInfo
    /// The stored baseline, if this app has been observed before.
    public var baseline: TrustRecord?
    /// The derived status.
    public var status: TrustStatus

    public init(
        bundleIdentifier: String?,
        signature: CodeSignatureInfo,
        baseline: TrustRecord?,
        status: TrustStatus
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.signature = signature
        self.baseline = baseline
        self.status = status
    }

    /// `true` when an automatic replacement would be blocked pending a decision.
    public var wouldBlockAutomaticReplacement: Bool {
        switch status {
        case .blockedUnsigned, .blockedSignatureInvalid, .blockedGatekeeperRejected,
             .identityUnreadable, .teamChangePending:
            return true
        case .verifiedTrusted, .firstUse, .degraded:
            return false
        }
    }

    /// The pending team-ID change, when that is what is blocking.
    public var pendingTeamChange: TeamIdentifierChange? {
        if case let .teamChangePending(change) = status { return change }
        return nil
    }
}

/// The derived trust status shared by the read-only evaluation and the gate.
public enum TrustStatus: Sendable, Hashable {
    /// Signature verified and the team ID matches the stored baseline.
    case verifiedTrusted(teamIdentifier: String?)
    /// Signature verified and no baseline yet — acting would record first-use.
    case firstUse(teamIdentifier: String?)
    /// Signature verified but the team ID differs from the baseline; needs opt-in.
    case teamChangePending(TeamIdentifierChange)
    /// The bundle is unsigned.
    case blockedUnsigned
    /// The signature is present but failed strict verification.
    case blockedSignatureInvalid(String)
    /// Gatekeeper rejected the bundle.
    case blockedGatekeeperRejected(String)
    /// No readable bundle identity — no silent fallback, manual clarification.
    case identityUnreadable
    /// A check could not run; proceeding would not assert security.
    case degraded(TrustDegradation)

    /// A short label for the status pill in the UI.
    public var label: String {
        switch self {
        case .verifiedTrusted: return String(localized: "trusted")
        case .firstUse: return String(localized: "First observation")
        case .teamChangePending: return String(localized: "Team ID change")
        case .blockedUnsigned: return String(localized: "not signed")
        case .blockedSignatureInvalid: return String(localized: "Signature invalid")
        case .blockedGatekeeperRejected: return String(localized: "Gatekeeper rejected")
        case .identityUnreadable: return String(localized: "Identity unreadable")
        case .degraded: return String(localized: "not checked")
        }
    }
}

/// Enforces the trust chain **before** OpenFreshr replaces an app bundle.
///
/// This is the single decision point the coordinators consult before any backend
/// runs. It is deliberately a value type over two injected dependencies —
/// a ``CodeSignatureInspecting`` and a ``TrustStoring`` — so the whole policy is
/// exercised through fakes and never touches real `codesign`, real Gatekeeper or
/// the disk in tests.
///
/// The policy, in order:
///
/// 1. **Unsigned or invalid signature → block.** Absence of a valid signature is
///    never auto-replaced.
/// 2. **Gatekeeper rejected → block.**
/// 3. **No bundle identity → block.** Ambiguous identity means manual
///    clarification, not a silent fallback.
/// 4. **No baseline → trust-on-first-use.** The observed team ID becomes the
///    baseline and the action proceeds. *Honest limitation:* if that first
///    install was already compromised, its team ID is what gets trusted.
/// 5. **Team ID unchanged → allow.**
/// 6. **Team ID changed → block** until the user explicitly opts in; the
///    confirmed change is then logged and the baseline advances.
/// 7. **A missing tool degrades that check** — the gate does not blanket-block,
///    but it reports the result as *unverified* rather than claiming safety.
public struct TrustGate: Sendable {

    private let inspector: any CodeSignatureInspecting
    private let store: any TrustStoring

    public init(inspector: any CodeSignatureInspecting, store: any TrustStoring) {
        self.inspector = inspector
        self.store = store
    }

    // MARK: - Read-only evaluation (UI)

    /// Compute the current trust picture for `app` **without** mutating the store.
    public func evaluate(_ app: InstalledApp) -> TrustEvaluation {
        let signature = inspector.inspect(bundlePath: app.bundlePath)
        let bundleID = Self.normalizedBundleIdentifier(app.bundleIdentifier)
        let baseline = bundleID.flatMap { store.record(for: $0) }
        let status = Self.assess(bundleIdentifier: bundleID, signature: signature, baseline: baseline)
        return TrustEvaluation(
            bundleIdentifier: bundleID,
            signature: signature,
            baseline: baseline,
            status: status
        )
    }

    // MARK: - Enforcement (coordinators)

    /// Decide whether `app` may be replaced now, recording trust as a side effect.
    ///
    /// - Parameters:
    ///   - app: the installed app about to be replaced.
    ///   - acknowledgeTeamChange: `true` only when the user has explicitly opted
    ///     in to a team-ID change for this specific app. A first-use baseline is
    ///     always recorded automatically; a change is recorded **only** with this
    ///     acknowledgement.
    ///   - now: the timestamp to stamp new records with (injectable for tests).
    public func authorize(
        _ app: InstalledApp,
        acknowledgeTeamChange: Bool = false,
        now: Date = Date()
    ) -> TrustDecision {
        let signature = inspector.inspect(bundlePath: app.bundlePath)
        let bundleID = Self.normalizedBundleIdentifier(app.bundleIdentifier)
        let baseline = bundleID.flatMap { store.record(for: $0) }
        let status = Self.assess(bundleIdentifier: bundleID, signature: signature, baseline: baseline)

        switch status {
        case .verifiedTrusted:
            return .allowed

        case let .firstUse(teamIdentifier):
            // Anchor the baseline only when there is an actual team to anchor. A
            // verified bundle with no readable team (Apple's own apps) is allowed
            // but leaves nothing to compare against later.
            if let bundleID, let teamIdentifier {
                store.save(TrustRecord(
                    bundleIdentifier: bundleID,
                    teamIdentifier: teamIdentifier,
                    firstObservedAt: now,
                    updatedAt: now,
                    origin: .firstUse
                ))
            }
            return .allowed

        case let .teamChangePending(change):
            guard acknowledgeTeamChange else { return .blocked(.teamIdentifierChanged(change)) }
            if let bundleID {
                let existing = store.record(for: bundleID)
                let confirmed = TrustChange(
                    previousTeamIdentifier: change.previousTeamIdentifier,
                    newTeamIdentifier: change.newTeamIdentifier,
                    confirmedAt: now
                )
                store.save(TrustRecord(
                    bundleIdentifier: bundleID,
                    teamIdentifier: change.newTeamIdentifier,
                    firstObservedAt: existing?.firstObservedAt ?? now,
                    updatedAt: now,
                    origin: .userConfirmedChange,
                    confirmedChanges: (existing?.confirmedChanges ?? []) + [confirmed]
                ))
            }
            return .allowed

        case .blockedUnsigned:
            return .blocked(.unsigned)
        case let .blockedSignatureInvalid(message):
            return .blocked(.signatureInvalid(message))
        case let .blockedGatekeeperRejected(message):
            return .blocked(.gatekeeperRejected(message))
        case .identityUnreadable:
            return .blocked(.identityUnreadable)
        case let .degraded(degradation):
            // A missing tool degrades the check: proceed, but do not claim security.
            return .allowedWithoutVerification(degradation)
        }
    }

    // MARK: - Trust management (UI)

    public func storedRecords() -> [TrustRecord] { store.allRecords() }
    public func resetTrust(bundleIdentifier: String) {
        if let normalized = Self.normalizedBundleIdentifier(bundleIdentifier) {
            store.reset(bundleIdentifier: normalized)
        }
    }
    public func resetAllTrust() { store.resetAll() }

    // MARK: - Pure policy

    /// The pure status decision, shared by ``evaluate(_:)`` and ``authorize(_:acknowledgeTeamChange:now:)``.
    /// Takes no dependencies and mutates nothing, so it is trivially testable.
    static func assess(
        bundleIdentifier: String?,
        signature: CodeSignatureInfo,
        baseline: TrustRecord?
    ) -> TrustStatus {
        switch signature.verification {
        case .unsigned:
            return .blockedUnsigned
        case let .invalid(message):
            return .blockedSignatureInvalid(message)
        case .toolUnavailable:
            // The signature basis is entirely unknown: degrade, do not claim safety.
            return .degraded(.signatureToolUnavailable)
        case .verified:
            break
        }

        if case let .rejected(message) = signature.gatekeeper {
            return .blockedGatekeeperRejected(message)
        }
        // A missing Gatekeeper tool does not skip the team-ID logic; the verified
        // signature still carries a team to anchor. The UI reflects the missing GK
        // check straight from `signature.gatekeeper`.

        guard let bundleIdentifier else {
            return .identityUnreadable
        }

        let observed = signature.teamIdentifier
        guard let baseline else {
            return .firstUse(teamIdentifier: observed)
        }
        guard let observed else {
            // A baseline exists but the current team is unreadable — cannot compare.
            return .degraded(.teamIdentifierUnreadable)
        }
        if observed == baseline.teamIdentifier {
            return .verifiedTrusted(teamIdentifier: observed)
        }
        return .teamChangePending(TeamIdentifierChange(
            bundleIdentifier: bundleIdentifier,
            previousTeamIdentifier: baseline.teamIdentifier,
            newTeamIdentifier: observed
        ))
    }

    /// Normalise a bundle identifier for use as a case-insensitive trust key.
    static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
