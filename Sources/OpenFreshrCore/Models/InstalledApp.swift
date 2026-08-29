import Foundation

/// A GUI application discovered by the local inventory scan.
///
/// This is the normalised, UI-free representation of one `.app` bundle. It is a
/// plain value type deliberately: the scanner reads it once from disk, and every
/// later stage (matching, adoption, the view model) works on the value without
/// touching the filesystem again. Nothing here depends on Homebrew — an app is
/// fully describable before the catalog is even loaded.
public struct InstalledApp: Hashable, Sendable, Codable, Identifiable {

    /// Absolute path of the `.app` bundle. Doubles as the stable identity: two
    /// bundles can share a name across scan directories, but not a path.
    public var bundlePath: String

    /// `CFBundleIdentifier`, lower-cased comparisons are the caller's job.
    ///
    /// May be `nil` when the `Info.plist` is missing or unreadable; the scan
    /// keeps the app rather than dropping it.
    public var bundleIdentifier: String?

    /// `CFBundleShortVersionString` — the human "marketing" version.
    ///
    /// Kept separate from ``bundleVersion`` on purpose: Homebrew's adopt path
    /// compares the cask version against *both* fields, so both must survive the
    /// scan intact.
    public var shortVersion: String?

    /// `CFBundleVersion` — the build version.
    public var bundleVersion: String?

    /// `true` when `Contents/_MASReceipt/receipt` exists.
    ///
    /// A Mac App Store receipt means a second update manager already owns the
    /// app; such apps are never offered for Homebrew adoption.
    public var hasMacAppStoreReceipt: Bool

    /// Value of `SUFeedURL` from the `Info.plist`, if present.
    ///
    /// An explicit feed is the reliable Sparkle signal. Stored as a string
    /// because a malformed feed URL must not derail the scan.
    public var sparkleFeedURL: String?

    /// `true` when `Contents/Frameworks/Sparkle.framework` exists but no feed URL
    /// was found.
    ///
    /// This is the "Sparkle present, feed unknown" case: it marks the app as
    /// self-updating without ever inventing an available version.
    public var hasSparkleFramework: Bool

    /// `true` when the bundle ships `Electron Framework.framework`.
    public var isElectron: Bool

    public init(
        bundlePath: String,
        bundleIdentifier: String? = nil,
        shortVersion: String? = nil,
        bundleVersion: String? = nil,
        hasMacAppStoreReceipt: Bool = false,
        sparkleFeedURL: String? = nil,
        hasSparkleFramework: Bool = false,
        isElectron: Bool = false
    ) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.hasMacAppStoreReceipt = hasMacAppStoreReceipt
        self.sparkleFeedURL = sparkleFeedURL
        self.hasSparkleFramework = hasSparkleFramework
        self.isElectron = isElectron
    }

    public var id: String { bundlePath }

    /// File name of the bundle including the `.app` extension, e.g. `Copilot.app`.
    ///
    /// This is the token matched against a cask's app artifact target, so it is
    /// derived from the path rather than from any plist field.
    public var bundleName: String {
        (bundlePath as NSString).lastPathComponent
    }

    /// Human-facing name without the `.app` extension.
    public var displayName: String {
        let name = bundleName
        guard name.hasSuffix(".app") else { return name }
        return String(name.dropLast(4))
    }

    /// The version shown to the user: short version first, build version as a
    /// fallback. `nil` when neither could be read.
    public var displayVersion: String? {
        if let shortVersion, !shortVersion.isEmpty { return shortVersion }
        if let bundleVersion, !bundleVersion.isEmpty { return bundleVersion }
        return nil
    }

    /// `true` when the bundle identifier lives in the `com.microsoft.` namespace,
    /// which Microsoft AutoUpdate services.
    public var isMicrosoftAutoUpdateManaged: Bool {
        (bundleIdentifier ?? "").lowercased().hasPrefix("com.microsoft.")
    }

    /// `true` for Apple's own bundles, serviced by `softwareupdate`.
    public var isAppleSoftwareUpdateManaged: Bool {
        (bundleIdentifier ?? "").lowercased().hasPrefix("com.apple.")
    }
}
