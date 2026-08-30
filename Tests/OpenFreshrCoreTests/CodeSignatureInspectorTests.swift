import Foundation
import Testing
@testable import OpenFreshrCore

/// The production ``SystemCodeSignatureInspector`` exercised through a
/// ``RecordingProcessRunner`` and a ``FakeFileSystem``: no real `codesign`,
/// no real `spctl`, no bundle on disk. It proves the four states the spec names
/// — verified, not verified (invalid), unsigned, and tool missing — plus the
/// Team-ID parsing rules and the exact, separated arguments the tools are given.
struct CodeSignatureInspectorTests {

    private let codesign = "/usr/bin/codesign"
    private let spctl = "/usr/sbin/spctl"

    /// A filesystem where both signing tools are present.
    private func toolsPresent() -> FakeFileSystem {
        var fs = FakeFileSystem()
        fs.addExistingPath(codesign)
        fs.addExistingPath(spctl)
        return fs
    }

    // MARK: - Verified

    @Test
    func verifiedBundleReportsTeamGatekeeperAndVerification() throws {
        let bundle = "/Applications/Example.app"
        let runner = RecordingProcessRunner { url, args in
            if url.path == self.codesign, args.first == "-dv" {
                // codesign -dv writes its display info to stderr.
                return ProcessResult(
                    exitCode: 0,
                    standardOutput: "",
                    standardError: "Executable=/Applications/Example.app/Contents/MacOS/Example\nTeamIdentifier=EQHXZ8M8AV\n"
                )
            }
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let inspector = SystemCodeSignatureInspector(processRunner: runner, fileSystem: toolsPresent())

        let info = inspector.inspect(bundlePath: bundle)

        #expect(info.verification == .verified)
        #expect(info.gatekeeper == .accepted)
        #expect(info.teamIdentifier == "EQHXZ8M8AV")
        #expect(info.isVerified)
        #expect(info.wasDegradedByMissingTool == false)

        // Separated arguments, absolute paths, path terminator before the bundle.
        #expect(runner.invocations.contains(.init(
            executablePath: codesign, arguments: ["--verify", "--strict", "--", bundle])))
        #expect(runner.invocations.contains(.init(
            executablePath: codesign, arguments: ["-dv", "--", bundle])))
        #expect(runner.invocations.contains(.init(
            executablePath: spctl, arguments: ["--assess", "--type", "execute", "--", bundle])))
    }

    // MARK: - Unsigned

    @Test
    func unsignedBundleIsClassifiedUnsignedNotInvalid() throws {
        let runner = RecordingProcessRunner { url, args in
            if url.path == self.codesign, args.first == "--verify" {
                return ProcessResult(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "/Applications/Foo.app: code object is not signed at all\n"
                )
            }
            // No team, no gatekeeper acceptance either.
            if url.path == self.spctl {
                return ProcessResult(exitCode: 3, standardOutput: "", standardError: "rejected\n")
            }
            return ProcessResult(exitCode: 1, standardOutput: "", standardError: "")
        }
        let inspector = SystemCodeSignatureInspector(processRunner: runner, fileSystem: toolsPresent())

        let info = inspector.inspect(bundlePath: "/Applications/Foo.app")

        #expect(info.verification == .unsigned)
        #expect(info.teamIdentifier == nil)
        #expect(info.isVerified == false)
    }

    // MARK: - Invalid (present but broken signature)

    @Test
    func brokenSignatureIsClassifiedInvalidWithMessage() throws {
        let runner = RecordingProcessRunner { url, args in
            if url.path == self.codesign, args.first == "--verify" {
                return ProcessResult(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: "/Applications/Bar.app: main executable failed strict validation\n"
                )
            }
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let inspector = SystemCodeSignatureInspector(processRunner: runner, fileSystem: toolsPresent())

        let info = inspector.inspect(bundlePath: "/Applications/Bar.app")

        guard case let .invalid(message) = info.verification else {
            Issue.record("expected .invalid, got \(info.verification)")
            return
        }
        #expect(message.contains("strict validation"))
        #expect(info.isVerified == false)
    }

    // MARK: - Tool missing

    @Test
    func missingToolsDegradeRatherThanBlock() throws {
        // Neither tool exists on this filesystem, and the runner must never be
        // consulted for them.
        let runner = RecordingProcessRunner { _, _ in
            Issue.record("process runner must not be called when the tool is absent")
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let inspector = SystemCodeSignatureInspector(processRunner: runner, fileSystem: FakeFileSystem())

        let info = inspector.inspect(bundlePath: "/Applications/Whatever.app")

        #expect(info.verification == .toolUnavailable)
        #expect(info.gatekeeper == .toolUnavailable)
        #expect(info.teamIdentifier == nil)
        #expect(info.wasDegradedByMissingTool)
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - Team-ID parsing rules

    @Test
    func teamIdentifierNotSetNormalisesToNil() {
        #expect(SystemCodeSignatureInspector.parseTeamIdentifier(
            from: "TeamIdentifier=not set\n") == nil)
        #expect(SystemCodeSignatureInspector.parseTeamIdentifier(
            from: "Identifier=com.apple.Foo\nTeamIdentifier=UBF8T346G9\n") == "UBF8T346G9")
        #expect(SystemCodeSignatureInspector.parseTeamIdentifier(
            from: "no team here\n") == nil)
    }
}
