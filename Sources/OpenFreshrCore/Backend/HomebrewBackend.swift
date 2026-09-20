import Foundation

/// How Homebrew should be driven to bring a cask's app up to its cask version.
/// The two verbs are **not** interchangeable:
///
/// * ``upgrade`` — the ordinary path. `brew upgrade --cask --greedy -- <token>`
///   moves a cask whose receipt is *behind* the cask version forward.
/// * ``reinstall`` — the drift path. A cask marked `auto_updates` can end up with
///   a receipt that already **matches** the cask version while the app on disk is
///   older (Homebrew skips the version check for such casks and writes the receipt
///   to the cask version regardless of what actually landed). `brew upgrade` then
///   sees receipt == cask and does nothing — reporting success without changing a
///   thing. `brew reinstall --cask -- <token>` re-downloads and installs the
///   current cask version, so the disk matches again. It is the only verb that
///   repairs a receipt-vs-disk drift.
/// * ``adoptThenReinstall`` — the merged take-over path for an app that is
///   confidently attributed to a cask Homebrew does **not** manage yet. It runs
///   two commands in order: `brew install --cask --adopt -- <token>` takes the
///   existing app over without re-downloading it, which writes the receipt to the
///   cask version while the old app is still on disk — exactly the drift shape
///   above. `brew reinstall --cask -- <token>` then lands the current version. The
///   two are one user action ("Aktualisieren"); adoption is a prerequisite step,
///   not a separate button.
public enum HomebrewUpdateStrategy: String, Sendable, Hashable {
    case upgrade
    case reinstall
    case adoptThenReinstall
}

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
public struct HomebrewBackend: AdoptingBackend, InstallingBackend {

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

    /// The newest **receipt** version Homebrew records per managed cask, parsed
    /// from `brew list --cask --versions` (lines of the form `token v1 v2 …`).
    ///
    /// This is the version Homebrew *believes* is installed — which, for casks
    /// marked `auto_updates`, can silently drift ahead of the app actually on
    /// disk. Capturing it is what lets the coordinator tell a genuine backlog
    /// (receipt behind cask ⇒ `upgrade`) apart from a drift (receipt already at
    /// the cask version while the disk lags ⇒ `reinstall`). The receipt is never
    /// treated as the truth about the update *state* — the disk always is — it is
    /// used only to choose the verb that actually lands the update.
    ///
    /// A token may list several installed versions; the **newest** by
    /// ``VersionComparator`` is kept, because that is the one Homebrew's own
    /// outdated/upgrade logic treats as current. Returns an empty map when brew
    /// is absent or the call fails — the caller then simply has no receipt to
    /// reason about and stays on the plain upgrade path.
    public func managedReceiptVersions() -> [String: String] {
        guard let brewURL = brewURL() else { return [:] }
        guard let result = try? processRunner.run(
            executableURL: brewURL,
            arguments: ["list", "--cask", "--versions"]
        ), result.didSucceed else {
            return [:]
        }
        var versions: [String: String] = [:]
        for line in result.standardOutput.split(whereSeparator: { $0.isNewline }) {
            let fields = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let token = fields.first, fields.count > 1 else { continue }
            guard let newest = Self.newestReceiptVersion(Array(fields.dropFirst())) else { continue }
            versions[token] = newest
        }
        return versions
    }

    /// Pick the newest version from a token's receipt list. A pair the comparator
    /// cannot order (or a tie) keeps the incumbent, so the result is stable and
    /// never invents an ordering — the same fail-closed stance as the comparator.
    static func newestReceiptVersion(_ versions: [String]) -> String? {
        guard var newest = versions.first else { return nil }
        for candidate in versions.dropFirst()
        where VersionComparator.compare(installed: newest, available: candidate) == .older {
            newest = candidate
        }
        return newest
    }

    /// Resolve the exact `brew upgrade` command for `caskToken`, or `nil` when
    /// Homebrew is absent or the token fails validation. The command is
    /// `brew upgrade --cask --greedy -- <token>` — `--greedy` so casks marked
    /// auto-updating are still upgraded on explicit request, `--` so the token
    /// can never be read as a flag, and never `--force`.
    public func resolveUpdateCommand(identifier: String) -> ResolvedCommand? {
        resolveUpdateCommand(identifier: identifier, strategy: .upgrade)
    }

    /// Resolve the exact brew command for `identifier` under `strategy`, or `nil`
    /// when Homebrew is absent or the token fails validation.
    ///
    /// `.upgrade` yields `brew upgrade --cask --greedy -- <token>`; `.reinstall`
    /// yields `brew reinstall --cask -- <token>`. Both keep the standing safety
    /// rules: a separated argument vector, a `--` terminator so the token can
    /// never be parsed as a flag, a strictly validated token, and **never**
    /// `--force`.
    public func resolveUpdateCommand(
        identifier: String, strategy: HomebrewUpdateStrategy
    ) -> ResolvedCommand? {
        guard let brewURL = brewURL() else { return nil }
        guard Self.isValidCaskToken(identifier) else { return nil }
        return ResolvedCommand(
            executablePath: brewURL.path,
            arguments: Self.arguments(for: strategy, token: identifier)
        )
    }

    /// The separated argument vector for a **single-step** strategy, kept in one
    /// place so the previewed command and the executed one can never diverge. For
    /// ``HomebrewUpdateStrategy/adoptThenReinstall`` this returns the *effective*
    /// (second) command — the reinstall that lands the update; the full ordered
    /// plan, including the adopt pre-step, is produced by ``commandPlan(for:token:)``.
    static func arguments(for strategy: HomebrewUpdateStrategy, token: String) -> [String] {
        commandPlan(for: strategy, token: token).last ?? []
    }

    /// The ordered argument vectors a strategy actually runs. A single entry for
    /// an ordinary ``HomebrewUpdateStrategy/upgrade`` or
    /// ``HomebrewUpdateStrategy/reinstall``; **two** for
    /// ``HomebrewUpdateStrategy/adoptThenReinstall``, where Homebrew first takes
    /// the app over and then lands the disk version. The single source of truth
    /// for both the preview and the execution of the merged take-over action.
    static func commandPlan(for strategy: HomebrewUpdateStrategy, token: String) -> [[String]] {
        switch strategy {
        case .upgrade:
            return [["upgrade", "--cask", "--greedy", "--", token]]
        case .reinstall:
            return [["reinstall", "--cask", "--", token]]
        case .adoptThenReinstall:
            return [adoptArguments(token: token), ["reinstall", "--cask", "--", token]]
        }
    }

    /// The separated argument vector that takes an existing app over without
    /// re-downloading it: `brew install --cask --adopt -- <token>`. `--`
    /// terminates option parsing so a token can never be read as a flag, and
    /// `--force` is **never** present. Single source of truth for the previewed
    /// and the executed adopt command alike.
    static func adoptArguments(token: String) -> [String] {
        ["install", "--cask", "--adopt", "--", token]
    }

    /// Resolve a strategy's full ordered plan into previewable, executable
    /// ``ResolvedCommand``s — the exact vectors the coordinator runs, in order.
    /// `nil` when `brew` is absent or the token is invalid, so a source can never
    /// fabricate a command it could not run.
    public func resolveCommandPlan(
        identifier: String, strategy: HomebrewUpdateStrategy
    ) -> [ResolvedCommand]? {
        guard let brewURL = brewURL() else { return nil }
        guard Self.isValidCaskToken(identifier) else { return nil }
        return Self.commandPlan(for: strategy, token: identifier).map {
            ResolvedCommand(executablePath: brewURL.path, arguments: $0)
        }
    }

    /// Update the cask `identifier` via `brew upgrade --cask --greedy -- <token>`.
    ///
    /// Reuses the adopt path's token validation and `CaskError` classification:
    /// the token is refused before launch on any violation, and a cask-level
    /// abort is reported distinctly from an ordinary non-zero exit.
    public func update(identifier: String) -> BackendActionResult {
        update(identifier: identifier, strategy: .upgrade)
    }

    /// Update the cask `identifier` under `strategy`.
    ///
    /// `.upgrade` runs `brew upgrade --cask --greedy -- <token>`; `.reinstall`
    /// runs `brew reinstall --cask -- <token>` to repair a receipt-vs-disk drift
    /// that `brew upgrade` would silently no-op. Both reuse the same token
    /// validation and `CaskError` classification: the token is refused before
    /// launch on any violation, and a cask-level abort is reported distinctly
    /// from an ordinary non-zero exit.
    public func update(
        identifier: String, strategy: HomebrewUpdateStrategy
    ) -> BackendActionResult {
        guard let command = resolveUpdateCommand(identifier: identifier, strategy: strategy) else {
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
                // a flag, even if validation were ever loosened. Same vector the
                // preview shows via `commandPlan(for: .adoptThenReinstall)`.
                arguments: Self.adoptArguments(token: caskToken)
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

    /// The separated argument vector for a **fresh install** of a new cask:
    /// `brew install --cask -- <token>`. No `--adopt` (there is no existing app
    /// to take over), no `--greedy`, and — as everywhere — **never** `--force`.
    /// `--` terminates option parsing so an externally sourced token can never be
    /// read as a flag. Single source of truth for the previewed and executed
    /// install command alike.
    static func installArguments(token: String) -> [String] {
        ["install", "--cask", "--", token]
    }

    /// Resolve the exact `brew install --cask -- <token>` command for a new cask,
    /// or `nil` when Homebrew is absent or the token fails validation — so the
    /// catalog can never offer to install something it could not actually run.
    public func resolveInstallCommand(identifier: String) -> ResolvedCommand? {
        guard let brewURL = brewURL() else { return nil }
        guard Self.isValidCaskToken(identifier) else { return nil }
        return ResolvedCommand(
            executablePath: brewURL.path,
            arguments: Self.installArguments(token: identifier)
        )
    }

    /// Install the new cask `caskToken` via `brew install --cask -- <token>`.
    ///
    /// Reuses the adopt path's exact safety posture: the token is validated
    /// against the strict allowlist and refused **before** any process launches,
    /// the argument vector is separated with a `--` terminator, and a cask-level
    /// abort is reported distinctly from an ordinary non-zero exit. The reported
    /// success is only a claim — the coordinator confirms it by rescanning the
    /// disk (or, for installer-only casks, by re-reading the managed set).
    public func install(caskToken: String) -> BackendActionResult {
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
                arguments: Self.installArguments(token: caskToken)
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
