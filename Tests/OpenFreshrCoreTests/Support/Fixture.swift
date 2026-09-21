import Foundation

@testable import OpenFreshrCore

/// Loads the checked-in fixtures (derived from `docs/research/coverage-result.json`
/// by `Fixtures/generate.py`) out of the test bundle.
enum Fixture {

    struct MissingFixtureError: Error { let name: String }

    /// The 109 foreign, update-relevant apps (coverage `covered` + `open`).
    static func installedApps() throws -> [InstalledApp] {
        try JSONDecoder().decode([InstalledApp].self, from: data(named: "installed-apps"))
    }

    /// The synthesised cask catalog, including the four mismatch traps.
    static func casks() throws -> [Cask] {
        try JSONDecoder().decode([Cask].self, from: data(named: "casks"))
    }

    /// One captured signing record from `code-signatures.json`.
    struct SignatureRecord: Decodable {
        let present: Bool
        let teamIdentifier: String?
        let verification: String
        let gatekeeper: String
    }

    /// The real code-signing facts of the reference machine, captured **once** by
    /// `Fixtures/capture-signatures.py` and consumed offline here, keyed by
    /// `bundlePath`. Tests never run `codesign`/`spctl`; they replay this map
    /// through ``FakeCodeSignatureInspector``.
    static func codeSignatures() throws -> [String: SignatureRecord] {
        try JSONDecoder().decode([String: SignatureRecord].self, from: data(named: "code-signatures"))
    }

    /// Convert the captured records into ``CodeSignatureInfo`` values the trust
    /// layer understands. Absent bundles collapse to `unsigned`/`rejected`, which
    /// is how a missing app would fail the gate anyway.
    static func codeSignatureInfos() throws -> [String: CodeSignatureInfo] {
        try codeSignatures().mapValues { record in
            let verification: SignatureVerification
            switch record.verification {
            case "verified": verification = .verified
            case "unsigned": verification = .unsigned
            default: verification = .invalid("captured: strict verification failed")
            }
            let gatekeeper: GatekeeperAssessment =
                record.gatekeeper == "accepted" ? .accepted : .rejected("captured: gatekeeper rejected")
            return CodeSignatureInfo(
                teamIdentifier: record.teamIdentifier,
                verification: verification,
                gatekeeper: gatekeeper
            )
        }
    }

    static func data(named name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures"
            )
        else {
            throw MissingFixtureError(name: name)
        }
        return try Data(contentsOf: url)
    }

    /// Find one app by its bundle file name, e.g. `Copilot.app`.
    static func app(named bundleName: String, in apps: [InstalledApp]) -> InstalledApp? {
        apps.first { $0.bundleName == bundleName }
    }
}
