import Foundation

/// The pure heart of update detection: turns a pair of version strings into an
/// ``UpdateState`` under one rule that never bends —
///
/// > **A version pair that cannot be compared with confidence yields
/// > `unbekannt`, never "Update verfügbar".**
///
/// A falsely reported update leads to an unnecessary — possibly destructive —
/// replacement, so every ambiguous outcome is funnelled into ``UpdateState/unknown(_:)``.
/// This type does no I/O and holds no state, which is exactly what lets the
/// safety rule be exhaustively unit-tested in isolation from feeds, tools and
/// scanners.
public enum UpdateResolver {

    /// Map an installed/available version pair to a state.
    ///
    /// * A missing installed version → `unknown(.noInstalledVersion)`.
    /// * A missing available version → `unknown(.noAvailableVersion)`.
    /// * Both present but not comparable → `unknown(.incomparableVersions)`.
    /// * Installed strictly older → `updateAvailable`, flagged major when the
    ///   first version component changes.
    /// * Installed equal or ahead → `upToDate`.
    public static func state(installed: String?, available: String?) -> UpdateState {
        guard let installed = installed.flatMap(nonEmpty) else {
            return .unknown(.noInstalledVersion)
        }
        guard let available = available.flatMap(nonEmpty) else {
            return .unknown(.noAvailableVersion)
        }
        switch VersionComparator.compare(installed: installed, available: available) {
        case .older:
            let isMajor = VersionComparator.isMajorChange(from: installed, to: available)
            return .updateAvailable(available: available, isMajor: isMajor)
        case .same, .newer:
            return .upToDate
        case .none:
            return .unknown(.incomparableVersions)
        }
    }

    private static func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
