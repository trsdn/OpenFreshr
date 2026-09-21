import Foundation

/// One application row parsed from `msupdate --list`.
public struct MsupdateAppEntry: Equatable, Sendable {
    /// The Microsoft AutoUpdate application ID (e.g. `MSWD2019`), used verbatim
    /// as `msupdate --install --apps <id>`.
    public var appID: String
    /// The app title as printed, for matching against an installed bundle.
    public var title: String
    /// The version `msupdate` lists, when one could be parsed.
    public var availableVersion: String?

    public init(appID: String, title: String, availableVersion: String?) {
        self.appID = appID
        self.title = title
        self.availableVersion = availableVersion
    }
}

/// Parses the output of `msupdate --list`.
///
/// The exact layout varies across Microsoft AutoUpdate releases, so parsing is
/// intentionally shape-tolerant but **anchored on the application ID**: only a
/// line carrying a bracketed/parenthesised MAU app code (e.g. `(MSWD2019)` or
/// `[MSWD2019]`) is treated as an app row. The app ID is what actually drives
/// `msupdate --install`, so requiring it keeps stray output from ever producing
/// a bogus entry. A version is attached only when a dotted-numeric token is
/// present; otherwise it stays `nil` and the resolver degrades to *unbekannt*
/// rather than inventing one.
public enum MsupdateListParser {

    public static func parse(_ output: String) -> [MsupdateAppEntry] {
        var entries: [MsupdateAppEntry] = []
        var seen = Set<String>()
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            guard let entry = parseLine(String(rawLine)) else { continue }
            guard !seen.contains(entry.appID) else { continue }
            seen.insert(entry.appID)
            entries.append(entry)
        }
        return entries
    }

    static func parseLine(_ line: String) -> MsupdateAppEntry? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let idMatch = appIDRegex.firstMatch(in: line, range: fullRange),
            let idRange = Range(idMatch.range(at: 1), in: line),
            let bracketRange = Range(idMatch.range, in: line)
        else {
            return nil
        }
        let appID = String(line[idRange])

        // Title: whatever precedes the bracket, stripped of list bullets.
        let titleRaw = String(line[line.startIndex..<bracketRange.lowerBound])
        let title =
            titleRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•·:").union(.whitespaces))

        // Version: first dotted-numeric token after the bracket, else anywhere.
        let afterRange = NSRange(bracketRange.upperBound..<line.endIndex, in: line)
        let version =
            firstVersion(in: line, range: afterRange)
            ?? firstVersion(in: line, range: fullRange)

        return MsupdateAppEntry(appID: appID, title: title, availableVersion: version)
    }

    private static func firstVersion(in line: String, range: NSRange) -> String? {
        guard let match = versionRegex.firstMatch(in: line, range: range),
            let versionRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[versionRange])
    }

    private static let appIDRegex = try! NSRegularExpression(
        pattern: #"[\(\[]([A-Za-z][A-Za-z0-9]{2,31})[\)\]]"#
    )

    private static let versionRegex = try! NSRegularExpression(
        pattern: #"\b([0-9]+(?:\.[0-9]+){1,3})\b"#
    )
}
