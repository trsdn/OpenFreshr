import Foundation

/// The captured result of running a subprocess.
public struct ProcessResult: Hashable, Sendable {
    /// Process exit status. `0` conventionally means success.
    public var exitCode: Int32
    /// Everything the process wrote to standard output.
    public var standardOutput: String
    /// Everything the process wrote to standard error.
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// `true` when the process exited `0`.
    public var didSucceed: Bool { exitCode == 0 }
}

/// Runs external executables with **separated arguments**.
///
/// The argument list is an array on purpose: there is no shell, no string
/// interpolation and therefore no command injection surface. `brew` is invoked
/// through this protocol, so tests substitute a fake and the real `brew` is
/// never touched by the suite.
public protocol ProcessRunning: Sendable {

    /// Run `executableURL` with `arguments`, wait for exit and capture output.
    ///
    /// - Parameters:
    ///   - executableURL: Absolute path to the executable. No `PATH` lookup is
    ///     performed — callers resolve the path explicitly.
    ///   - arguments: Already-split argument vector; passed through untouched.
    ///   - environment: Optional environment override; `nil` inherits the
    ///     current process environment.
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> ProcessResult

    /// The same call, given up on after `timeout` seconds.
    ///
    /// Most tools here are local and fast; a few reach the network (`npm
    /// outdated`, `softwareupdate --list`) and were observed, on a real machine,
    /// to hang far longer than that ever justifies — `npm outdated -g` sat
    /// blocked for minutes with no output, and `softwareupdate` can report
    /// another caller is already using it and then never return. Without a
    /// bound, one contended tool would leave a check silently stuck forever
    /// rather than degrading to ``EcosystemCheck/unknown(_:)``, the one outcome
    /// this contract exists to avoid.
    ///
    /// The default implementation ignores `timeout` and calls the plain
    /// `run(executableURL:arguments:environment:)` — the right choice for a
    /// process that has never been seen to hang, and for every test fake, which
    /// returns synchronously anyway. Only ``SystemProcessRunner`` enforces it.
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessResult
}

extension ProcessRunning {
    /// Convenience overload that inherits the current environment.
    public func run(executableURL: URL, arguments: [String]) throws -> ProcessResult {
        try run(executableURL: executableURL, arguments: arguments, environment: nil)
    }

    /// Default: no enforcement. See the protocol requirement's documentation.
    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try run(executableURL: executableURL, arguments: arguments, environment: environment)
    }
}

/// `Foundation.Process`-backed implementation.
///
/// Marked `@unchecked Sendable`: it holds no mutable state, but `Foundation`
/// does not annotate `Process`/`Pipe` as `Sendable`. Each call builds its own
/// process, so there is nothing to share across threads.
public struct SystemProcessRunner: ProcessRunning, @unchecked Sendable {

    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> ProcessResult {
        try runProcess(executableURL: executableURL, arguments: arguments, environment: environment, timeout: nil)
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try runProcess(
            executableURL: executableURL, arguments: arguments, environment: environment, timeout: timeout)
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // A watchdog that terminates the process if it outlives `timeout`. Racing
        // it against the blocking reads below (rather than only against
        // `waitUntilExit()`) matters: a process that stops producing output but
        // never closes its pipes would otherwise hang `readDataToEndOfFile()`
        // forever regardless of this timer, so `terminate()` — which closes the
        // process's file descriptors — is what actually unblocks the read.
        var timedOut = false
        let timedOutLock = NSLock()
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOutLock.lock()
                timedOut = true
                timedOutLock.unlock()
                process.terminate()
            }
            watchdog = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
        }

        // Read before waiting to avoid dead-locking on a full pipe buffer.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()

        timedOutLock.lock()
        let wasTimedOut = timedOut
        timedOutLock.unlock()

        var standardError = String(decoding: stderrData, as: UTF8.self)
        var exitCode = process.terminationStatus
        if wasTimedOut {
            // The real termination status (typically a signal-related negative
            // value) is noise next to the actual cause; say what happened instead,
            // and force a non-zero code so a caller's ordinary "did it succeed"
            // check cannot mistake this for a real result.
            standardError = "OpenFreshr stopped waiting after \(Int(timeout ?? 0))s."
            if exitCode == 0 { exitCode = -1 }
        }

        return ProcessResult(
            exitCode: exitCode,
            standardOutput: String(decoding: stdoutData, as: UTF8.self),
            standardError: standardError
        )
    }
}
