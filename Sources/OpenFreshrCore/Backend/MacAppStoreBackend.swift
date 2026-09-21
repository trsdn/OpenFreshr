import Foundation

/// The Mac App Store implementation of ``PackageBackend``, driving Argon's
/// `mas` command-line tool.
///
/// The same rules as ``HomebrewBackend`` apply:
///
/// * **`mas` is located explicitly** at `/opt/homebrew/bin/mas` (Apple silicon)
///   or `/usr/local/bin/mas` (Intel), never resolved via `PATH`, because a GUI
///   process does not inherit the interactive shell environment.
/// * **The identifier is validated before use.** A Mac App Store adam ID is a
///   run of digits; anything else is refused before a process is launched, so a
///   value sourced from tool output can never be read as a flag.
/// * **A missing `mas` degrades the source** — ``isAvailable()`` returns `false`
///   and ``resolveUpdateCommand(identifier:)`` returns `nil`, so the App Store
///   source simply shows as `unbekannt` rather than blocking anything.
public struct MacAppStoreBackend: PackageBackend {

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidateMasPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidateMasPaths: [String] = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidateMasPaths = candidateMasPaths
    }

    /// The first existing `mas` path, or `nil` when it is not installed.
    public func masURL() -> URL? {
        for path in candidateMasPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool {
        masURL() != nil
    }

    /// Resolve `mas upgrade <id>` for a validated adam ID, or `nil` when `mas`
    /// is absent or the identifier is not a plain run of digits.
    public func resolveUpdateCommand(identifier: String) -> ResolvedCommand? {
        guard let masURL = masURL() else { return nil }
        guard Self.isValidAppStoreID(identifier) else { return nil }
        return ResolvedCommand(
            executablePath: masURL.path,
            arguments: ["upgrade", identifier]
        )
    }

    /// Run `mas outdated` and return the parsed entries, or `nil` when `mas` is
    /// unavailable or the run fails. A `nil` here *degrades* the App Store source
    /// to `unbekannt`; it is never treated as "everything is up to date".
    public func outdated() -> [MasOutdatedEntry]? {
        guard let masURL = masURL() else { return nil }
        guard
            let result = try? processRunner.run(
                executableURL: masURL,
                arguments: ["outdated"]
            )
        else {
            return nil
        }
        guard result.didSucceed else { return nil }
        return MasOutdatedParser.parse(result.standardOutput)
    }

    public func update(identifier: String) -> BackendActionResult {
        guard let command = resolveUpdateCommand(identifier: identifier) else {
            if masURL() == nil { return .failed(reason: .toolUnavailable(tool: "mas")) }
            return .failed(reason: .invalidIdentifier(identifier))
        }

        let result: ProcessResult
        do {
            result = try processRunner.run(
                executableURL: URL(fileURLWithPath: command.executablePath),
                arguments: command.arguments
            )
        } catch {
            return .failed(reason: .launchFailed(message: String(describing: error)))
        }

        if result.didSucceed {
            return .succeeded(standardOutput: result.standardOutput)
        }
        return .failed(
            reason: .processFailed(exitCode: result.exitCode, standardError: result.standardError)
        )
    }

    /// A Mac App Store adam ID: one or more ASCII digits and nothing else. The
    /// anchors are `\A…\z` (not `^…$`) so a trailing newline cannot slip through.
    static func isValidAppStoreID(_ identifier: String) -> Bool {
        Self.appStoreIDRegex.firstMatch(
            in: identifier,
            range: NSRange(identifier.startIndex..<identifier.endIndex, in: identifier)
        ) != nil
    }

    private static let appStoreIDRegex = try! NSRegularExpression(
        pattern: "\\A[0-9]{1,15}\\z"
    )
}
