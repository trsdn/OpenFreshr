import Foundation

/// The production ``CodeSignatureInspecting``: shells out to the macOS signing
/// tools through the shared ``ProcessRunning`` mechanism.
///
/// Design rules it obeys, all for the same reasons the package backends do:
///
/// * **Absolute executable paths.** `/usr/bin/codesign` and `/usr/sbin/spctl`
///   are fixed system locations. A GUI app does not inherit the shell's `PATH`,
///   so a bare `codesign` would simply not be found — the paths are hard-coded,
///   not looked up.
/// * **Separated arguments.** Every argument is a distinct array element; there
///   is no shell and therefore no interpolation or injection surface.
/// * **Honest degradation.** If a tool is missing (its path does not exist) or
///   fails to launch, the corresponding check returns `toolUnavailable` rather
///   than throwing or, worse, pretending the bundle passed.
public struct SystemCodeSignatureInspector: CodeSignatureInspecting {

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading

    private let codesignPath = "/usr/bin/codesign"
    private let spctlPath = "/usr/sbin/spctl"

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        fileSystem: any FileSystemReading = SystemFileSystem()
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
    }

    public func inspect(bundlePath: String) -> CodeSignatureInfo {
        CodeSignatureInfo(
            teamIdentifier: readTeamIdentifier(bundlePath: bundlePath),
            verification: verify(bundlePath: bundlePath),
            gatekeeper: assess(bundlePath: bundlePath)
        )
    }

    // MARK: - codesign --verify --strict

    private func verify(bundlePath: String) -> SignatureVerification {
        guard fileSystem.fileExists(atPath: codesignPath) else { return .toolUnavailable }
        guard let result = try? processRunner.run(
            executableURL: URL(fileURLWithPath: codesignPath),
            arguments: ["--verify", "--strict", "--", bundlePath]
        ) else {
            return .toolUnavailable
        }

        if result.didSucceed { return .verified }

        // codesign writes its reason to stderr. An unsigned bundle is a distinct
        // fact from a present-but-broken signature, so classify it explicitly.
        let message = firstMeaningfulLine(result.standardError, fallback: result.standardOutput)
        if Self.indicatesUnsigned(result.standardError) || Self.indicatesUnsigned(result.standardOutput) {
            return .unsigned
        }
        return .invalid(message)
    }

    private static func indicatesUnsigned(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("not signed at all") || lowered.contains("is not signed")
    }

    // MARK: - codesign -dv  (Team ID)

    private func readTeamIdentifier(bundlePath: String) -> String? {
        guard fileSystem.fileExists(atPath: codesignPath) else { return nil }
        guard let result = try? processRunner.run(
            executableURL: URL(fileURLWithPath: codesignPath),
            arguments: ["-dv", "--", bundlePath]
        ) else {
            return nil
        }
        // `codesign -dv` prints the display information to **stderr**, including a
        // `TeamIdentifier=...` line. It reads `not set` for Apple's own apps,
        // which we normalise to `nil` — there is no third-party team to anchor.
        return Self.parseTeamIdentifier(from: result.standardError)
            ?? Self.parseTeamIdentifier(from: result.standardOutput)
    }

    /// Extract the `TeamIdentifier=` value from `codesign -dv` output. Returns
    /// `nil` when absent or literally `not set`.
    static func parseTeamIdentifier(from text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "TeamIdentifier=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.caseInsensitiveCompare("not set") == .orderedSame {
                return nil
            }
            return value
        }
        return nil
    }

    // MARK: - spctl --assess --type execute

    private func assess(bundlePath: String) -> GatekeeperAssessment {
        guard fileSystem.fileExists(atPath: spctlPath) else { return .toolUnavailable }
        guard let result = try? processRunner.run(
            executableURL: URL(fileURLWithPath: spctlPath),
            arguments: ["--assess", "--type", "execute", "--", bundlePath]
        ) else {
            return .toolUnavailable
        }
        if result.didSucceed { return .accepted }
        let message = firstMeaningfulLine(result.standardError, fallback: result.standardOutput)
        return .rejected(message)
    }

    // MARK: - Helpers

    private func firstMeaningfulLine(_ primary: String, fallback: String) -> String {
        let source = primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : primary
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
