import Foundation

/// The Homebrew implementation of ``PackageBackend``.
///
/// Three verified facts from the spec shape this type:
///
/// * **`brew` is located explicitly.** A GUI process does not inherit the
///   interactive shell `PATH`, so the executable is probed at
///   `/opt/homebrew/bin/brew` and `/usr/local/bin/brew` instead of by name.
/// * **Adoption uses a separated argument vector.** The command is
///   `["install", "--cask", "--adopt", "--", token]`; there is no shell, no
///   `--force` ever, and `--` terminates option parsing so an externally
///   sourced token can never be smuggled in as a flag. The token is also
///   validated against a strict allowlist before use.
/// * **A `CaskError` is detected and reported distinctly** from other failures,
///   so a version-mismatch hard-fail is never mistaken for "nothing happened".
public struct HomebrewBackend: AdoptingBackend {

    private let processRunner: any ProcessRunning
    private let fileSystem: any FileSystemReading

    /// Candidate `brew` locations, in priority order. Apple-silicon default
    /// first, Intel default second — the same paths Homebrew itself documents.
    private let candidateBrewPaths: [String]

    public init(
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemReading,
        candidateBrewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.candidateBrewPaths = candidateBrewPaths
    }

    /// The first existing `brew` path, or `nil` when Homebrew is not installed.
    public func brewURL() -> URL? {
        for path in candidateBrewPaths where fileSystem.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func isAvailable() -> Bool {
        brewURL() != nil
    }

    public func managedTokens() -> Set<String> {
        guard let brewURL = brewURL() else { return [] }
        guard let result = try? processRunner.run(
            executableURL: brewURL,
            arguments: ["list", "--cask", "-1"]
        ) else {
            return []
        }
        guard result.didSucceed else { return [] }
        let tokens = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(tokens)
    }

    /// Resolve the exact `brew upgrade` command for `caskToken`, or `nil` when
    /// Homebrew is absent or the token fails validation. The command is
    /// `brew upgrade --cask --greedy -- <token>` — `--greedy` so casks marked
    /// auto-updating are still upgraded on explicit request, `--` so the token
    /// can never be read as a flag, and never `--force`.
    public func resolveUpdateCommand(identifier: String) -> ResolvedCommand? {
        guard let brewURL = brewURL() else { return nil }
        guard Self.isValidCaskToken(identifier) else { return nil }
        return ResolvedCommand(
            executablePath: brewURL.path,
            arguments: ["upgrade", "--cask", "--greedy", "--", identifier]
        )
    }

    /// Update the cask `identifier` via `brew upgrade --cask --greedy -- <token>`.
    ///
    /// Reuses the adopt path's token validation and `CaskError` classification:
    /// the token is refused before launch on any violation, and a cask-level
    /// abort is reported distinctly from an ordinary non-zero exit.
    public func update(identifier: String) -> BackendActionResult {
        guard let command = resolveUpdateCommand(identifier: identifier) else {
            if brewURL() == nil { return .failed(reason: .homebrewUnavailable) }
            return .failed(reason: .invalidCaskToken(identifier))
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

        let combined = result.standardError + "\n" + result.standardOutput
        if let caskErrorMessage = Self.caskErrorMessage(in: combined) {
            return .caskError(message: caskErrorMessage)
        }

        return .failed(
            reason: .processFailed(
                exitCode: result.exitCode,
                standardError: result.standardError
            )
        )
    }

    /// Adopt `app` as `caskToken` via `brew install --cask --adopt <token>`.
    ///
    /// `app` is currently only used to keep the signature honest for later
    /// phases (e.g. logging which bundle was adopted); the command itself is
    /// fully determined by the token, which is exactly why it is safe.
    public func adopt(app: InstalledApp, caskToken: String) -> BackendActionResult {
        guard let brewURL = brewURL() else {
            return .failed(reason: .homebrewUnavailable)
        }

        // The token comes from external catalog data. Validate it against a
        // strict allowlist *before* it is ever placed on a command line, and
        // hard-fail on any violation — never silently continue.
        guard Self.isValidCaskToken(caskToken) else {
            return .failed(reason: .invalidCaskToken(caskToken))
        }

        let result: ProcessResult
        do {
            result = try processRunner.run(
                executableURL: brewURL,
                // `--` terminates option parsing so a token can never be read as
                // a flag, even if validation were ever loosened.
                arguments: ["install", "--cask", "--adopt", "--", caskToken]
            )
        } catch {
            return .failed(reason: .launchFailed(message: String(describing: error)))
        }

        if result.didSucceed {
            return .succeeded(standardOutput: result.standardOutput)
        }

        // Homebrew prints "Error: ... " to stderr and, for adopt version
        // mismatches, an explicit CaskError. Detect that specific hard-fail so
        // the coordinator can tell it apart from an ordinary failure.
        let combined = result.standardError + "\n" + result.standardOutput
        if let caskErrorMessage = Self.caskErrorMessage(in: combined) {
            return .caskError(message: caskErrorMessage)
        }

        return .failed(
            reason: .processFailed(
                exitCode: result.exitCode,
                standardError: result.standardError
            )
        )
    }

    /// Extract a `CaskError` message from combined brew output, or `nil`.
    ///
    /// Recognises both the explicit `CaskError` class name Homebrew emits and the
    /// characteristic adopt refusal ("It seems there is already an App at ...")
    /// so a version-mismatch abort is classified even across brew versions.
    static func caskErrorMessage(in output: String) -> String? {
        let lines = output.split(whereSeparator: { $0.isNewline }).map(String.init)
        for line in lines {
            let lower = line.lowercased()
            let looksLikeAdoptRefusal =
                lower.contains("already an app at") && lower.contains("adopt")
            if lower.contains("caskerror") || looksLikeAdoptRefusal {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        // Fallback: an "Error:" line mentioning adopt is still a cask-level abort.
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("error:") && lower.contains("adopt") {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// A Homebrew cask token, restricted to exactly what real tokens use: a
    /// lowercase letter or digit, then lowercase letters, digits and
    /// `@ + . _ -`. A leading `-`, whitespace, uppercase, an empty string, or any
    /// other character is rejected — which is what stops `-v`, `--appdir=/tmp/x`
    /// or `; rm -rf` from ever reaching `brew`.
    ///
    /// The anchors are `\A…\z` (absolute start/end), **not** `^…$`: in ICU regex
    /// `$` also matches just before a trailing newline, so `^…$` would accept
    /// `"token\n"`. `\z` matches only the very end of the string, closing that
    /// gap so an embedded trailing newline can never slip through.
    static func isValidCaskToken(_ token: String) -> Bool {
        Self.caskTokenRegex.firstMatch(
            in: token,
            range: NSRange(token.startIndex..<token.endIndex, in: token)
        ) != nil
    }

    private static let caskTokenRegex = try! NSRegularExpression(
        pattern: "\\A[a-z0-9][a-z0-9@+._-]*\\z"
    )
}
