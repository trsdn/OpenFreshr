import Foundation

/// A fully resolved command line: an **absolute** executable path and an
/// already-split argument vector.
///
/// This is the single source of truth shared by the preview UI and the actual
/// execution, so the string the user is shown in the confirmation sheet and the
/// vector the process runner receives can never drift apart. Execution always
/// uses ``arguments`` verbatim through ``ProcessRunning`` — there is no shell —
/// and ``displayString`` exists purely to render the command for a human.
public struct ResolvedCommand: Hashable, Sendable {

    /// Absolute path to the executable (`/opt/homebrew/bin/brew`, the MAU
    /// `msupdate` binary inside its app bundle, …). Never resolved via `PATH`.
    public var executablePath: String

    /// The already-split argument vector, passed through untouched.
    public var arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    /// A copy-pasteable, shell-quoted rendering of the command. **Display only** —
    /// nothing ever executes this string. Tokens that are not obviously safe
    /// (e.g. the MAU path, which contains spaces) are single-quoted so the
    /// preview reads like a command a user could paste.
    public var displayString: String {
        ([executablePath] + arguments).map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        let isSafe = token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: return true            // 0-9 A-Z a-z
            case 0x40, 0x2B, 0x2E, 0x5F, 0x2D, 0x2F, 0x3D, 0x3A: return true // @ + . _ - / = :
            default: return false
            }
        }
        if isSafe { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
