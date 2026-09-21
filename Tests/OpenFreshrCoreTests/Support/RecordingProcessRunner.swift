import Foundation

@testable import OpenFreshrCore

/// A ``ProcessRunning`` that records every invocation and returns a programmed
/// result, so `HomebrewBackend` can be exercised without launching `brew`.
///
/// `@unchecked Sendable`: the recorded invocations are guarded by a lock, which
/// the compiler cannot verify but which makes concurrent access safe.
final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {

    struct Invocation: Sendable, Equatable {
        var executablePath: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private let handler: @Sendable (URL, [String]) -> ProcessResult

    /// - Parameter handler: Produces the result for a given executable/arguments
    ///   pair. Defaults to a generic success.
    init(
        handler: @escaping @Sendable (URL, [String]) -> ProcessResult = { _, _ in
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    ) {
        self.handler = handler
    }

    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) throws -> ProcessResult {
        lock.lock()
        _invocations.append(
            Invocation(executablePath: executableURL.path, arguments: arguments)
        )
        lock.unlock()
        return handler(executableURL, arguments)
    }
}
