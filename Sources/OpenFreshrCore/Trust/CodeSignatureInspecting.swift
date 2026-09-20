import Foundation

/// The verdict of `codesign --verify --strict` on an app bundle.
///
/// The three "real" cases are kept distinct on purpose: a bundle that is
/// *unsigned* is a different fact from one whose signature is *present but
/// broken*, and both differ from *the tool being unavailable*. The trust gate
/// treats the first two as hard blocks and the third as an honest degradation —
/// never as a silent "looks fine".
public enum SignatureVerification: Sendable, Hashable {
    /// `codesign --verify --strict` exited `0`: the signature is intact.
    case verified
    /// The bundle carries no signature at all (`code object is not signed`).
    case unsigned
    /// A signature is present but failed strict verification. Carries the tool's
    /// own explanation so the UI can quote it verbatim.
    case invalid(String)
    /// `codesign` could not be located or launched. The check did not run; no
    /// security claim can be made either way.
    case toolUnavailable
}

/// The verdict of Gatekeeper (`spctl --assess --type execute`).
public enum GatekeeperAssessment: Sendable, Hashable {
    /// Gatekeeper accepted the bundle for execution.
    case accepted
    /// Gatekeeper rejected the bundle. Carries the tool's explanation.
    case rejected(String)
    /// `spctl` could not be located or launched. The check did not run.
    case toolUnavailable
}

/// Everything the trust layer can learn about one on-disk app bundle from the
/// system signing tools, gathered in a single inspection.
///
/// `teamIdentifier` is `nil` when it cannot be read — either because the bundle
/// is unsigned, because `codesign` reports `TeamIdentifier=not set` (Apple's own
/// system apps), or because the tool was unavailable. A `nil` here is never
/// treated as a trusted anchor; it degrades the *team-change* comparison instead
/// of silently passing it.
public struct CodeSignatureInfo: Sendable, Hashable {
    /// The Apple Developer Team ID from the signature, or `nil` when unreadable.
    public var teamIdentifier: String?
    /// The strict-verification verdict.
    public var verification: SignatureVerification
    /// The Gatekeeper verdict.
    public var gatekeeper: GatekeeperAssessment

    public init(
        teamIdentifier: String?,
        verification: SignatureVerification,
        gatekeeper: GatekeeperAssessment
    ) {
        self.teamIdentifier = teamIdentifier
        self.verification = verification
        self.gatekeeper = gatekeeper
    }

    /// `true` only when strict verification actively passed. Unsigned, invalid
    /// **and** tool-unavailable are all `false`: absence of proof is not proof.
    public var isVerified: Bool {
        if case .verified = verification { return true }
        return false
    }

    /// `true` when either signing tool was missing, so the corresponding check
    /// could not run. The gate degrades (does not blanket-block) in this case but
    /// must not present the result as verified.
    public var wasDegradedByMissingTool: Bool {
        if case .toolUnavailable = verification { return true }
        if case .toolUnavailable = gatekeeper { return true }
        return false
    }
}

/// Reads code-signing facts for an app bundle.
///
/// Hidden behind a protocol for the same reason every other platform touch is:
/// the real implementation shells out to `/usr/bin/codesign` and
/// `/usr/sbin/spctl`, and the test suite substitutes a fake so **no test ever
/// runs a real signature check** or depends on how this machine's apps happen to
/// be signed.
public protocol CodeSignatureInspecting: Sendable {
    /// Inspect the bundle at `bundlePath`, gathering team ID, strict-verification
    /// and Gatekeeper facts in one call. Never throws: an unrunnable tool becomes
    /// a `toolUnavailable` verdict, not an error the caller must handle.
    func inspect(bundlePath: String) -> CodeSignatureInfo
}
