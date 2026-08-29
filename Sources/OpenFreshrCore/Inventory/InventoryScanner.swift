import Foundation

/// Scans one or more directories for installed `.app` bundles and normalises each
/// into an ``InstalledApp``.
///
/// The scanner is deliberately observational and injectable:
///
/// * It reads through ``FileSystemReading``, so tests point it at a fixture tree
///   and it never looks at the real `/Applications`.
/// * The scan roots are parameters, not constants.
/// * It never fails the whole scan for one unreadable bundle — a missing or
///   corrupt `Info.plist` yields an app with `nil` fields, not a thrown error,
///   because a half-readable Mac still deserves a complete inventory.
///
/// It has no knowledge of Homebrew; provenance is attached later by the catalog.
public struct InventoryScanner: Sendable {

    private let fileSystem: any FileSystemReading

    /// Bundle identifiers that are never real user-facing apps (helper droplets).
    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.shortcuts.droplet"
    ]

    /// Display-name prefixes that mark throwaway installer/backup bundles.
    private static let ignoredNamePrefixes: [String] = [
        "Hermes-Setup-Backup"
    ]

    public init(fileSystem: any FileSystemReading) {
        self.fileSystem = fileSystem
    }

    /// The default scan roots on macOS. Exposed so the app can use them and tests
    /// can ignore them.
    public static let defaultScanDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        // User-local installs are exactly the phase-1 target group, so the
        // per-user Applications folder must be scanned too. Expanded eagerly
        // because the scanner takes literal directory paths.
        ("~/Applications" as NSString).expandingTildeInPath
    ]

    /// Scan `directories` and return the de-duplicated inventory.
    ///
    /// Apps are de-duplicated by bundle file name, first directory wins — the
    /// same policy the coverage research used, so a copy in a secondary root does
    /// not double-count.
    public func scan(directories: [String]) -> [InstalledApp] {
        var seenNames = Set<String>()
        var result: [InstalledApp] = []

        for directory in directories {
            let entries = (try? fileSystem.contentsOfDirectory(atPath: directory)) ?? []
            for path in entries.sorted() where path.hasSuffix(".app") {
                let name = (path as NSString).lastPathComponent
                guard !seenNames.contains(name) else { continue }

                guard let app = makeApp(atBundlePath: path) else { continue }
                guard !isNoise(app) else { continue }

                seenNames.insert(name)
                result.append(app)
            }
        }
        return result
    }

    /// Build an ``InstalledApp`` from a bundle path, reading its `Info.plist` and
    /// probing marker files. Returns `nil` only when the path is not a plausible
    /// bundle at all.
    private func makeApp(atBundlePath bundlePath: String) -> InstalledApp? {
        let contents = (bundlePath as NSString).appendingPathComponent("Contents")

        let info = readInfoPlist(atContentsPath: contents)

        let masReceipt = (contents as NSString)
            .appendingPathComponent("_MASReceipt/receipt")
        let hasReceipt = fileSystem.fileExists(atPath: masReceipt)

        let sparkleFramework = (contents as NSString)
            .appendingPathComponent("Frameworks/Sparkle.framework")
        let hasSparkle = fileSystem.fileExists(atPath: sparkleFramework)

        let electronFramework = (contents as NSString)
            .appendingPathComponent("Frameworks/Electron Framework.framework")
        let isElectron = fileSystem.fileExists(atPath: electronFramework)

        let feedURL = (info["SUFeedURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return InstalledApp(
            bundlePath: bundlePath,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            bundleVersion: info["CFBundleVersion"] as? String,
            hasMacAppStoreReceipt: hasReceipt,
            sparkleFeedURL: feedURL,
            // Only flag the runtime when there is a framework but no explicit feed.
            hasSparkleFramework: hasSparkle && feedURL == nil,
            isElectron: isElectron
        )
    }

    /// Read and parse `Contents/Info.plist`, tolerating every failure mode by
    /// returning an empty dictionary.
    private func readInfoPlist(atContentsPath contents: String) -> [String: Any] {
        let plistPath = (contents as NSString).appendingPathComponent("Info.plist")
        guard let data = try? fileSystem.contents(ofFile: plistPath) else {
            return [:]
        }
        let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return (parsed as? [String: Any]) ?? [:]
    }

    /// Filter out helper/installer bundles that are not user-managed apps.
    private func isNoise(_ app: InstalledApp) -> Bool {
        if let bundleID = app.bundleIdentifier,
           Self.ignoredBundleIdentifiers.contains(bundleID) {
            return true
        }
        let display = app.displayName
        return Self.ignoredNamePrefixes.contains { display.hasPrefix($0) }
    }
}
