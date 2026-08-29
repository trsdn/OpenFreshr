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
}

extension ProcessRunning {
    /// Convenience overload that inherits the current environment.
    public func run(executableURL: URL, arguments: [String]) throws -> ProcessResult {
        try run(executableURL: executableURL, arguments: arguments, environment: nil)
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

        // Read before waiting to avoid dead-locking on a full pipe buffer.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: stdoutData, as: UTF8.self),
            standardError: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
