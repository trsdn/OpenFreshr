import Foundation

/// A prepared, immutable search index over the whole cask catalog.
///
/// The catalog is large (thousands of casks) and the search field runs on every
/// keystroke, so the expensive work — lowercasing every token, name and
/// description, resolving popularity, and deciding whether each cask is already
/// installed — happens **once** at construction. A query then only walks
/// precomputed lowercased haystacks looking for substring matches, which keeps
/// typing responsive even over the full catalog.
///
/// The type is a `Sendable` value with no reference state, so it is built off
/// the main actor (see the catalog view model) and handed back for the UI to
/// query synchronously.
public struct CatalogSearchIndex: Sendable {

    /// One prepared entry: the result the UI wants plus the search key and the
    /// sort keys, all computed up front.
    private struct Entry: Sendable {
        var result: CatalogSearchResult
        /// Space-joined, lowercased token/names/old-tokens/description — the only
        /// string a query ever scans.
        var haystack: String
        /// Lowercased display name, for the stable alphabetical tiebreak.
        var sortName: String
        /// Popularity used for ranking; unknown popularity sorts below any known
        /// count but never removes the cask from results.
        var rank: Int
    }

    /// Entries pre-sorted into the canonical ranked order (popularity desc, then
    /// name asc), so an empty query is just "return everything" and a non-empty
    /// query preserves ranking by filtering in place.
    private let entries: [Entry]

    /// Number of casks the index can search.
    public var count: Int { entries.count }

    /// Build the index.
    ///
    /// - Parameters:
    ///   - catalog: the cask snapshot to index.
    ///   - analytics: optional install-count source for popularity ranking.
    ///     When absent, every cask ranks equally and results fall back to a
    ///     stable alphabetical order.
    ///   - installedBundleNames: filenames of app bundles found on disk
    ///     (e.g. `"Firefox.app"`), compared case-insensitively against each
    ///     cask's moved-artifact targets to mark it already installed.
    ///   - recognizedTokens: cask tokens already matched to an installed app,
    ///     so a cask is marked installed even when its artifact filename differs
    ///     from what landed on disk.
    public init(
        catalog: CaskCatalog,
        analytics: CaskInstallAnalytics? = nil,
        installedBundleNames: Set<String> = [],
        recognizedTokens: Set<String> = []
    ) {
        let installedLowercased = Set(installedBundleNames.map { $0.lowercased() })

        var built: [Entry] = []
        built.reserveCapacity(catalog.casks.count)

        for cask in catalog.casks {
            let installedBundleName = cask.movedArtifactTargets.first {
                installedLowercased.contains($0.lowercased())
            }
            let isInstalled =
                installedBundleName != nil
                || recognizedTokens.contains(cask.token)

            let installCount = analytics?.installs(for: cask.token)

            let result = CatalogSearchResult(
                cask: cask,
                installCount: installCount,
                isInstalled: isInstalled,
                installedBundleName: installedBundleName,
                isInstallerOnly: cask.isInstallerOnly
            )

            built.append(
                Entry(
                    result: result,
                    haystack: Self.haystack(for: cask),
                    sortName: (cask.names.first ?? cask.token).lowercased(),
                    rank: installCount ?? -1
                )
            )
        }

        built.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
            if lhs.sortName != rhs.sortName { return lhs.sortName < rhs.sortName }
            return lhs.result.cask.token < rhs.result.cask.token
        }

        self.entries = built
    }

    /// Search the catalog.
    ///
    /// The query is lowercased and split on whitespace; a cask matches when its
    /// haystack contains **every** term (AND semantics), so "visual studio"
    /// narrows rather than widens. An empty or whitespace-only query returns the
    /// whole catalog in ranked order (browse mode). Results keep the index's
    /// canonical ranking.
    ///
    /// - Parameter limit: optional cap on the number of results returned.
    public func search(_ rawQuery: String, limit: Int? = nil) -> [CatalogSearchResult] {
        let terms =
            rawQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let matched: [CatalogSearchResult]
        if terms.isEmpty {
            matched = entries.map(\.result)
        } else {
            var out: [CatalogSearchResult] = []
            for entry in entries where terms.allSatisfy({ entry.haystack.contains($0) }) {
                out.append(entry.result)
                if let limit, out.count >= limit { return out }
            }
            return out
        }

        if let limit, matched.count > limit {
            return Array(matched.prefix(limit))
        }
        return matched
    }

    /// The whole catalog in ranked order — browse mode with no query.
    public func allRanked(limit: Int? = nil) -> [CatalogSearchResult] {
        search("", limit: limit)
    }

    /// Build the lowercased search key for a cask: token (both dashed and
    /// space-separated so multi-word queries hit the token), any old tokens,
    /// declared names, and the description when present.
    private static func haystack(for cask: Cask) -> String {
        var parts: [String] = [
            cask.token,
            cask.token.replacingOccurrences(of: "-", with: " "),
        ]
        parts.append(contentsOf: cask.oldTokens)
        parts.append(contentsOf: cask.names)
        if let desc = cask.desc { parts.append(desc) }
        return parts.joined(separator: " ").lowercased()
    }
}
