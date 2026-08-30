import Foundation

/// The Homebrew 365-day cask install counts, keyed by cask token.
///
/// Fetched from `analytics/cask-install/365d.json` and cached alongside the
/// catalog. Phase 5 (the searchable catalog) ranks results by popularity from
/// this table; it is loaded and cached now — even though no surface reads it yet
/// — so a fresh install already has the data when that phase lands.
///
/// The document is treated as an **untrusted** input like every other network
/// response: it is parsed defensively with ``Foundation/JSONSerialization`` and a
/// malformed body yields an empty table, never a crash. It carries no identity
/// and feeds only ranking, so it never touches the corroboration/veto path.
public struct CaskInstallAnalytics: Sendable, Equatable {

    /// Cask token → number of installs observed over the trailing 365 days.
    public let installCountsByToken: [String: Int]

    public init(installCountsByToken: [String: Int]) {
        self.installCountsByToken = installCountsByToken
    }

    /// The install count for `token`, if the analytics document listed it.
    public func installs(for token: String) -> Int? {
        installCountsByToken[token]
    }

    /// Number of ranked casks (i.e. entries with a usable count).
    public var count: Int { installCountsByToken.count }

    /// Parse the raw analytics bytes. Best-effort: an unexpected shape or a
    /// missing field is skipped, and a wholly unparsable body returns an empty
    /// table rather than throwing — popularity is a nicety, never load-critical.
    public static func parse(fromAPIData data: Data) -> CaskInstallAnalytics {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [Any] else {
            return CaskInstallAnalytics(installCountsByToken: [:])
        }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(items.count)
        for element in items {
            guard let item = element as? [String: Any],
                  let token = item["cask"] as? String,
                  let installs = installCount(item["count"]) else { continue }
            // Keep the largest count if a token somehow appears twice.
            counts[token] = max(counts[token] ?? 0, installs)
        }
        return CaskInstallAnalytics(installCountsByToken: counts)
    }

    /// Homebrew reports the count as a comma-grouped string (`"6,190,417"`); some
    /// mirrors emit a bare number. Accept either, rejecting anything else.
    static func installCount(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            let digits = string.filter { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        return nil
    }
}
