import Foundation

/// Precomputed lookup tables over a set of casks.
///
/// Building these once turns matching from an O(apps × casks) scan into a few
/// dictionary lookups per app, and — more importantly — it makes the two kinds
/// of bundle-identifier knowledge explicit and separate:
///
/// * ``casksByAppTarget`` drives the **strong** signal (app file name equals a
///   moved-artifact target).
/// * ``primaryIdentityTokens`` records each cask's *own* identity, consulted by
///   the veto rule.
/// * ``cleanupIdentityTokens`` records *foreign* identifiers a cask cleans up,
///   which can only ever produce a **weak** suggestion.
public struct CaskIndex: Sendable {

    /// Lower-cased app target file name → cask tokens that ship it.
    public let casksByAppTarget: [String: [String]]

    /// Lower-cased bundle id → cask tokens that declare it as primary identity.
    public let primaryIdentityTokens: [String: [String]]

    /// Lower-cased bundle id → cask tokens that reference it in cleanup stanzas.
    public let cleanupIdentityTokens: [String: [String]]

    /// Normalised display name/token → cask tokens, for the weak name signal.
    public let casksByNormalizedName: [String: [String]]

    /// Token → cask, including `old_tokens` aliases pointing at the current cask.
    public let casksByToken: [String: Cask]

    public init(casks: [Cask]) {
        var byAppTarget: [String: [String]] = [:]
        var primary: [String: [String]] = [:]
        var cleanup: [String: [String]] = [:]
        var byName: [String: [String]] = [:]
        var byToken: [String: Cask] = [:]

        for cask in casks {
            byToken[cask.token] = cask

            for target in cask.movedArtifactTargets {
                byAppTarget[target.lowercased(), default: []].append(cask.token)
            }
            for identifier in cask.primaryBundleIdentifiers {
                primary[identifier.lowercased(), default: []].append(cask.token)
            }
            for identifier in cask.cleanupBundleIdentifiers {
                cleanup[identifier.lowercased(), default: []].append(cask.token)
            }

            var names = cask.names + [cask.token] + cask.oldTokens
            names = names.map(Self.normalizeName)
            for name in names where !name.isEmpty {
                byName[name, default: []].append(cask.token)
            }
        }

        self.casksByAppTarget = byAppTarget
        self.primaryIdentityTokens = primary
        self.cleanupIdentityTokens = cleanup
        self.casksByNormalizedName = byName
        self.casksByToken = byToken
    }

    /// Look up a cask by token.
    public func cask(for token: String) -> Cask? {
        casksByToken[token]
    }

    /// Normalise a display name or token to a comparison key: lower-cased,
    /// stripped of spaces, hyphens and the `.app` suffix.
    static func normalizeName(_ raw: String) -> String {
        var value = raw.lowercased()
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        return value.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }
}
