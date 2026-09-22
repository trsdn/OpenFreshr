import Foundation
import Testing

@testable import OpenFreshrCore

/// Exercises the real `Foundation.Process`-backed runner, not a fake — the
/// timeout enforcement lives entirely in `SystemProcessRunner` (the protocol's
/// default implementation intentionally ignores it), so it is only proven by
/// actually running a process.
@Suite("SystemProcessRunner")
struct SystemProcessRunnerTests {

    private let runner = SystemProcessRunner()

    @Test("A process that finishes well inside the timeout returns its real result")
    func fastProcessSucceeds() throws {
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], environment: nil, timeout: 5)
        #expect(result.didSucceed)
        #expect(result.standardOutput == "hi\n")
    }

    @Test("A process that outlives the timeout is terminated and reported, not left hanging")
    func slowProcessIsTerminated() throws {
        let start = Date()
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: nil, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10, "still took \(elapsed)s — the watchdog did not cut the wait short")
        #expect(!result.didSucceed)
        #expect(result.standardError.contains("1s"))
    }

    @Test("Without a timeout, the plain overload is unaffected")
    func noTimeoutOverloadStillWorks() throws {
        let result = try runner.run(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"])
        #expect(result.standardOutput == "ok\n")
    }
}
