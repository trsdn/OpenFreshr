import Foundation

/// The Microsoft AutoUpdate (MAU) implementation of ``PackageBackend``, driving
/// the `msupdate` binary that ships inside the Microsoft AutoUpdate app bundle.
///
/// MAU is the one self-updating mechanism OpenFreshr is allowed to *drive*: it
/// exists precisely to update Microsoft apps, so running it does not create the
/// two-updaters-fighting hazard that Sparkle would. Even so the same discipline
/// applies:
///
/// * **`msupdate` is located explicitly** inside
///   `/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app`,
///   never via `PATH`. The path contains spaces, which is exactly why the
///   command is always executed as a separated argument vector and never as a
///   shell string.
/// * **The app identifier is validated before use.** MAU application IDs are
///   short alphanumeric codes (e.g. `MSWD` for Word); anything else is refused
///   before launch.
/// * **A missing `msupdate` degrades the source** rather than blocking.
public struct MicrosoftAutoUpdateBackend: PackageBackend {

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading
    private let candidateMsupdatePaths: [String]

    /// The documented default location of the `msupdate` binary.
    public static let defaultMsupdatePath =
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidateMsupdatePaths: [String] = [MicrosoftAutoUpdateBackend.defaultMsupdatePath]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidateMsupdatePaths = candidateMsupdatePaths
    }

    /// The first existing `msupdate` path, or `nil` when MAU is not installed.
    public func msupdateURL() -> URL? {
        for path in candidateMsupdatePaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool {
        msupdateURL() != nil
    }

    /// Resolve `msupdate --install --apps <id>` for a validated MAU app ID, or
    /// `nil` when `msupdate` is absent or the identifier fails validation.
    public func resolveUpdateCommand(identifier: String) -> ResolvedCommand? {
        guard let msupdateURL = msupdateURL() else { return nil }
        guard Self.isValidAppID(identifier) else { return nil }
        return ResolvedCommand(
            executablePath: msupdateURL.path,
            arguments: ["--install", "--apps", identifier]
        )
    }

    /// Run `msupdate --list` and return the parsed entries, or `nil` when
    /// `msupdate` is unavailable or the run fails. A `nil` here *degrades* the
    /// Microsoft AutoUpdate source to `unbekannt` rather than blocking.
    public func list() -> [MsupdateAppEntry]? {
        guard let msupdateURL = msupdateURL() else { return nil }
        guard let result = try? processRunner.run(
            executableURL: msupdateURL,
            arguments: ["--list"]
        ) else {
            return nil
        }
        guard result.didSucceed else { return nil }
        return MsupdateListParser.parse(result.standardOutput)
    }

    public func update(identifier: String) -> BackendActionResult {
        guard let command = resolveUpdateCommand(identifier: identifier) else {
            if msupdateURL() == nil { return .failed(reason: .toolUnavailable(tool: "msupdate")) }
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

    /// A MAU application ID: 2–32 ASCII letters/digits and nothing else — enough
    /// for the four-character codes (`MSWD`, `XCEL`, `PPT3`, `ONMC`, …) and the
    /// longer variants, while refusing separators, spaces and flags. Anchored
    /// with `\A…\z` so a trailing newline cannot slip through.
    static func isValidAppID(_ identifier: String) -> Bool {
        Self.appIDRegex.firstMatch(
            in: identifier,
            range: NSRange(identifier.startIndex..<identifier.endIndex, in: identifier)
        ) != nil
    }

    private static let appIDRegex = try! NSRegularExpression(
        pattern: "\\A[A-Za-z0-9]{2,32}\\z"
    )
}
