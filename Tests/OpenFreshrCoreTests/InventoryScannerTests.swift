import Testing
@testable import OpenFreshrCore

/// The inventory scan: plist parsing, marker detection, the noise filter and the
/// cross-directory de-duplication — all driven through an in-memory filesystem so
/// the real `/Applications` is never touched.
struct InventoryScannerTests {

    @Test
    func parsesVersionsAndBundleIdentifierFromInfoPlist() {
        let app = InstalledApp(
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: "com.example.app",
            shortVersion: "3.4.5",
            bundleVersion: "3405"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        let scanned = scanner.scan(directories: ["/Applications"])

        #expect(scanned.count == 1)
        #expect(scanned.first?.bundleIdentifier == "com.example.app")
        #expect(scanned.first?.shortVersion == "3.4.5")
        #expect(scanned.first?.bundleVersion == "3405")
        #expect(scanned.first?.bundleName == "Example.app")
        #expect(scanned.first?.displayName == "Example")
    }

    @Test
    func detectsMacAppStoreReceipt() {
        let app = InstalledApp(
            bundlePath: "/Applications/Storey.app",
            bundleIdentifier: "com.example.storey",
            hasMacAppStoreReceipt: true
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        #expect(scanner.scan(directories: ["/Applications"]).first?.hasMacAppStoreReceipt == true)
    }

    @Test
    func readsSparkleFeedURLAndDoesNotAlsoFlagRuntime() {
        let app = InstalledApp(
            bundlePath: "/Applications/Feedly.app",
            bundleIdentifier: "com.example.feedly",
            sparkleFeedURL: "https://example.com/appcast.xml"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        let scanned = scanner.scan(directories: ["/Applications"]).first
        #expect(scanned?.sparkleFeedURL == "https://example.com/appcast.xml")
        // A readable feed is the reliable signal; the "framework present, feed
        // unknown" flag must stay off so one app is not counted as two signals.
        #expect(scanned?.hasSparkleFramework == false)
    }

    @Test
    func flagsSparkleRuntimeWhenFrameworkPresentButNoFeed() {
        let app = InstalledApp(
            bundlePath: "/Applications/Runtimey.app",
            bundleIdentifier: "com.example.runtimey",
            hasSparkleFramework: true
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        let scanned = scanner.scan(directories: ["/Applications"]).first
        #expect(scanned?.hasSparkleFramework == true)
        #expect(scanned?.sparkleFeedURL == nil)
    }

    @Test
    func detectsElectronFramework() {
        let app = InstalledApp(
            bundlePath: "/Applications/Electra.app",
            bundleIdentifier: "com.example.electra",
            isElectron: true
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        #expect(scanner.scan(directories: ["/Applications"]).first?.isElectron == true)
    }

    @Test
    func keepsAppEvenWhenInfoPlistIsMissing() {
        var fileSystem = FakeFileSystem()
        fileSystem.addBundleWithoutInfoPlist(atPath: "/Applications/Broken.app")
        let scanner = InventoryScanner(fileSystem: fileSystem)

        let scanned = scanner.scan(directories: ["/Applications"])
        // A half-readable Mac still deserves a complete inventory: the bundle is
        // kept with nil fields rather than dropped.
        #expect(scanned.count == 1)
        #expect(scanned.first?.bundleName == "Broken.app")
        #expect(scanned.first?.bundleIdentifier == nil)
    }

    @Test
    func filtersOutIgnoredBundleIdentifiers() {
        let droplet = InstalledApp(
            bundlePath: "/Applications/Some Shortcut.app",
            bundleIdentifier: "com.apple.shortcuts.droplet"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [droplet]))

        #expect(scanner.scan(directories: ["/Applications"]).isEmpty)
    }

    @Test
    func filtersOutIgnoredNamePrefixes() {
        let backup = InstalledApp(
            bundlePath: "/Applications/Hermes-Setup-Backup-98765.app",
            bundleIdentifier: "com.example.hermes.backup"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [backup]))

        #expect(scanner.scan(directories: ["/Applications"]).isEmpty)
    }

    @Test
    func deduplicatesByBundleNameFirstDirectoryWins() {
        let primary = InstalledApp(
            bundlePath: "/Applications/Duplicate.app",
            bundleIdentifier: "com.example.primary"
        )
        let secondary = InstalledApp(
            bundlePath: "/Applications/Utilities/Duplicate.app",
            bundleIdentifier: "com.example.secondary"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [primary, secondary]))

        let scanned = scanner.scan(directories: ["/Applications", "/Applications/Utilities"])
        #expect(scanned.count == 1)
        #expect(scanned.first?.bundlePath == "/Applications/Duplicate.app")
        #expect(scanned.first?.bundleIdentifier == "com.example.primary")
    }

    @Test
    func toleratesUnknownScanDirectories() {
        let app = InstalledApp(
            bundlePath: "/Applications/Only.app",
            bundleIdentifier: "com.example.only"
        )
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: [app]))

        // A scan root that does not exist must degrade to "nothing here", not fail
        // the whole scan.
        let scanned = scanner.scan(directories: ["/Applications", "/does/not/exist"])
        #expect(scanned.count == 1)
        #expect(scanned.first?.bundleName == "Only.app")
    }

    @Test
    func loadsAllFixtureAppsThroughAFakeFilesystem() throws {
        let apps = try Fixture.installedApps()
        let scanner = InventoryScanner(fileSystem: FakeFileSystem(apps: apps))

        // Round-trip the whole coverage-derived inventory: every app is placed on
        // the fake disk and read back, proving the scanner handles the real shape.
        let scanned = scanner.scan(directories: ["/Applications"])
        #expect(scanned.count == apps.count)
    }
}
