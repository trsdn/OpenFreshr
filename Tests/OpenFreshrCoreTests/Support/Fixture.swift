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

    static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            throw MissingFixtureError(name: name)
        }
        return try Data(contentsOf: url)
    }

    /// Find one app by its bundle file name, e.g. `Copilot.app`.
    static func app(named bundleName: String, in apps: [InstalledApp]) -> InstalledApp? {
        apps.first { $0.bundleName == bundleName }
    }
}
