import Foundation

/// How much confidence a cask match carries.
///
/// The whole safety model of OpenFreshr rests on this two-level distinction:
///
/// * ``strong`` — the app's own file name equals a cask's `app`/`suite` artifact
///   target. This is the only signal allowed to authorise an adoption, and even
///   it can be revoked by the veto rule.
/// * ``weak`` — a bundle identifier found in a cask's cleanup stanzas, or a
///   name resemblance. Weak matches are shown as suggestions and can *never*
///   authorise an adoption on their own.
public enum MatchStrength: String, Hashable, Sendable, Codable, Comparable {
    case weak
    case strong

    private var order: Int {
        switch self {
        case .weak: return 0
        case .strong: return 1
        }
    }

    public static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool {
        lhs.order < rhs.order
    }
}

/// Why a cask was proposed for an app. Carries the evidence so the UI can
/// explain a suggestion and the resolver can apply the veto rule.
public enum MatchReason: Hashable, Sendable, Codable {

    /// The app file name equals the cask's moved-artifact target. Strong.
    /// Associated value is the matched target file name (e.g. `Copilot.app`).
    case appArtifact(target: String)

    /// The app's bundle identifier appeared in a cask cleanup stanza
    /// (`zap`/`uninstall`). Weak — the identifier may belong to other software.
    case bundleIdentifierInStanza(identifier: String)

    /// The app display name resembles the cask token/name. Weak.
    case nameSimilarity(caskName: String)

    /// Baseline strength implied by the reason, before any veto is applied.
    public var baseStrength: MatchStrength {
        switch self {
        case .appArtifact: return .strong
        case .bundleIdentifierInStanza, .nameSimilarity: return .weak
        }
    }

    /// Short human explanation for the UI.
    public var explanation: String {
        switch self {
        case let .appArtifact(target):
            return "Cask liefert das App-Artefakt \(target)"
        case let .bundleIdentifierInStanza(identifier):
            return "Bundle-ID \(identifier) taucht in einer Cleanup-Stanza auf"
        case let .nameSimilarity(caskName):
            return "Name ähnelt dem Cask \(caskName)"
        }
    }
}

/// A resolved link between one installed app and one candidate cask.
///
/// The `strength` is the *effective* strength after the resolver has applied the
/// veto rule, which is why it is stored rather than recomputed from `reason`:
/// a vetoed `appArtifact` reason keeps its evidence but is demoted to ``weak``.
public struct AppMatch: Hashable, Sendable, Codable, Identifiable {

    /// Bundle path of the matched app — ties the match back to its ``InstalledApp``.
    public var appBundlePath: String

    /// The candidate cask token.
    public var caskToken: String

    /// Effective strength after veto handling.
    public var strength: MatchStrength

    /// The evidence for the match.
    public var reason: MatchReason

    /// `true` when a strong artifact match was revoked by the veto rule because
    /// the app's bundle identifier contradicts the cask's primary identity.
    /// Surfaced so the UI can warn instead of silently hiding the candidate.
    public var vetoed: Bool

    public init(
        appBundlePath: String,
        caskToken: String,
        strength: MatchStrength,
        reason: MatchReason,
        vetoed: Bool = false
    ) {
        self.appBundlePath = appBundlePath
        self.caskToken = caskToken
        self.strength = strength
        self.reason = reason
        self.vetoed = vetoed
    }

    public var id: String { "\(appBundlePath)|\(caskToken)" }
}
