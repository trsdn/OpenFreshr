import Foundation
@testable import OpenFreshrCore

/// An in-memory ``FileSystemReading`` built from ``InstalledApp`` values.
///
/// It reconstructs exactly the on-disk shape the scanner probes — a `Contents`
/// folder, an `Info.plist`, and the `_MASReceipt` / `Sparkle.framework` /
/// `Electron Framework.framework` markers — so a test can round-trip an app
/// through the real ``InventoryScanner`` without ever touching `/Applications`.
struct FakeFileSystem: FileSystemReading {

    struct UnknownDirectoryError: Error { let path: String }

    private var directoryChildren: [String: [String]] = [:]
    private var existingPaths: Set<String> = []
    private var files: [String: Data] = [:]

    init() {}

    /// Build a filesystem containing every app in `apps`.
    init(apps: [InstalledApp]) {
        for app in apps { addBundle(app) }
    }

    /// Add a fully-formed app bundle derived from an ``InstalledApp``.
    mutating func addBundle(_ app: InstalledApp) {
        let parent = (app.bundlePath as NSString).deletingLastPathComponent
        directoryChildren[parent, default: []].append(app.bundlePath)
        existingPaths.insert(parent)
        existingPaths.insert(app.bundlePath)

        let contents = (app.bundlePath as NSString).appendingPathComponent("Contents")
        existingPaths.insert(contents)

        var info: [String: Any] = [:]
        if let value = app.bundleIdentifier { info["CFBundleIdentifier"] = value }
        if let value = app.shortVersion { info["CFBundleShortVersionString"] = value }
        if let value = app.bundleVersion { info["CFBundleVersion"] = value }
        if let value = app.sparkleFeedURL { info["SUFeedURL"] = value }
        if !info.isEmpty {
            let plistPath = (contents as NSString).appendingPathComponent("Info.plist")
            files[plistPath] = try! PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            existingPaths.insert(plistPath)
        }

        if app.hasMacAppStoreReceipt {
            existingPaths.insert((contents as NSString).appendingPathComponent("_MASReceipt/receipt"))
        }
        // The scanner treats "framework present + no feed" as the runtime marker
        // and "framework present + feed" as an explicit Sparkle feed, so place
        // the framework whenever either signal is set on the source app.
        if app.hasSparkleFramework || app.sparkleFeedURL != nil {
            existingPaths.insert((contents as NSString).appendingPathComponent("Frameworks/Sparkle.framework"))
        }
        if app.isElectron {
            existingPaths.insert((contents as NSString).appendingPathComponent("Frameworks/Electron Framework.framework"))
        }
    }

    /// Mark an arbitrary path as existing (e.g. a `brew` executable location),
    /// without giving it any readable contents.
    mutating func addExistingPath(_ path: String) {
        existingPaths.insert(path)
    }

    /// Add a bare `.app` directory that has no `Info.plist` at all, to test the
    /// scanner's resilience to unreadable bundles.
    mutating func addBundleWithoutInfoPlist(atPath path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        directoryChildren[parent, default: []].append(path)
        existingPaths.insert(parent)
        existingPaths.insert(path)
    }

    // MARK: FileSystemReading

    func contentsOfDirectory(atPath directory: String) throws -> [String] {
        guard let children = directoryChildren[directory] else {
            throw UnknownDirectoryError(path: directory)
        }
        return children
    }

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }

    func contents(ofFile path: String) throws -> Data {
        guard let data = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }
}
