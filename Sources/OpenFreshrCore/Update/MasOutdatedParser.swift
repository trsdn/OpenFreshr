import Foundation

/// One row of `mas outdated`: a Mac App Store app with an update pending.
public struct MasOutdatedEntry: Equatable, Sendable {
    /// The App Store adam ID, used verbatim as `mas upgrade <id>`.
    public var identifier: String
    /// The app's name as `mas` prints it.
    public var name: String
    /// The currently installed version, per `mas`.
    public var installedVersion: String
    /// The available version, per `mas`.
    public var availableVersion: String

    public init(identifier: String, name: String, installedVersion: String, availableVersion: String) {
        self.identifier = identifier
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
    }
}

/// Parses the output of `mas outdated`.
///
/// The tool prints one line per outdated app in the form:
///
/// ```
/// 497799835 Xcode (14.0 -> 14.1)
/// 1295203466 Microsoft Remote Desktop (10.7.6 -> 10.8.0)
/// ```
///
/// Parsing is conservative: a line that does not match this exact shape is
/// skipped rather than guessed at, so noise never becomes a phantom update.
public enum MasOutdatedParser {

    public static func parse(_ output: String) -> [MasOutdatedEntry] {
        output
            .split(whereSeparator: { $0.isNewline })
            .compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> MasOutdatedEntry? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = lineRegex.firstMatch(in: line, range: range),
              match.numberOfRanges == 5,
              let idRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line),
              let oldRange = Range(match.range(at: 3), in: line),
              let newRange = Range(match.range(at: 4), in: line) else {
            return nil
        }
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return MasOutdatedEntry(
            identifier: String(line[idRange]),
            name: name,
            installedVersion: String(line[oldRange]).trimmingCharacters(in: .whitespaces),
            availableVersion: String(line[newRange]).trimmingCharacters(in: .whitespaces)
        )
    }

    /// `<digits> <name> ( <old> -> <new> )` — the name is captured lazily so the
    /// trailing parenthesised version pair is not swallowed into it.
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\s*([0-9]+)\s+(.+?)\s+\(([^()]*?)\s*->\s*([^()]*?)\)\s*$"#
    )
}
