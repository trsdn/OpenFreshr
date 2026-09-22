import Foundation

/// One update `softwareupdate --list` reported.
public struct SoftwareUpdateItem: Equatable, Sendable {
    /// The label `softwareupdate --install <label>` would act on (e.g.
    /// `macOS Tahoe  26.7-25G229`). Kept only for a future install path; nothing
    /// today runs a command built from it.
    public var label: String
    /// The human title (`macOS Tahoe  26.7`, `Safari`), for display.
    public var title: String
    public var version: String?
    public var recommended: Bool
    /// `true` when Apple's own listing says installing this needs a restart.
    public var requiresRestart: Bool

    public init(label: String, title: String, version: String?, recommended: Bool, requiresRestart: Bool) {
        self.label = label
        self.title = title
        self.version = version
        self.recommended = recommended
        self.requiresRestart = requiresRestart
    }
}

/// Parses the output of `softwareupdate --list`.
///
/// The tool prints progress and, on a machine with `--no-scan` or a scan that is
/// already busy, an error line (`Scan finished with error: …`) *ahead of* the
/// real listing — this was observed directly, not assumed. Parsing therefore
/// looks only for the two-line shape a real entry has (`* Label: …` followed by
/// an indented `Title: …` line) and ignores every other line, including an error
/// banner, silently. A `Title:` line with no matching `Label:` line just above it
/// produces nothing, which is the safe default: no entry is better than a
/// mismatched one.
public enum SoftwareUpdateListParser {

    public static func parse(_ output: String) -> [SoftwareUpdateItem] {
        var items: [SoftwareUpdateItem] = []
        var pendingLabel: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let label = label(in: line) {
                pendingLabel = label
                continue
            }
            if let label = pendingLabel, let item = titleItem(in: line, label: label) {
                items.append(item)
            }
            pendingLabel = nil
        }
        return items
    }

    private static func label(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("* Label: ") else { return nil }
        return String(trimmed.dropFirst("* Label: ".count))
    }

    private static func titleItem(in line: String, label: String) -> SoftwareUpdateItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Title: ") else { return nil }
        // The line is comma-separated key/value pairs, but the *last* field keeps a
        // trailing comma (only the line's own trailing whitespace was trimmed, not
        // the separator itself), so every field is trimmed again before matching.
        let fields = trimmed.dropFirst("Title: ".count).components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        guard let title = fields.first, !title.isEmpty else { return nil }
        var version: String?
        var recommended = false
        var requiresRestart = false
        for field in fields.dropFirst() {
            if field.hasPrefix("Version: ") { version = String(field.dropFirst("Version: ".count)) }
            if field.hasPrefix("Recommended: ") { recommended = field.hasSuffix("YES") }
            if field.hasPrefix("Action: ") { requiresRestart = field.contains("restart") }
        }
        return SoftwareUpdateItem(
            label: label, title: title, version: version, recommended: recommended,
            requiresRestart: requiresRestart)
    }
}
