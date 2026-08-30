import Foundation

/// Whether OpenFreshr itself has a newer published release available.
///
/// The comparison is **fail-closed**, exactly like the third-party update path:
/// an unreachable or unparsable feed, or a pair of versions that cannot be
/// ordered with confidence, resolves to ``Availability/unknown`` — never a
/// guessed update. A self-update is only ever asserted for an unambiguous
/// "installed < published".
public struct SelfUpdateStatus: Sendable, Equatable {

    public enum Availability: Sendable, Equatable {
        /// A newer version is published; carries that marketing version string.
        case updateAvailable(version: String)
        /// The running copy is the newest the feed offers (or is ahead of it).
        case upToDate
        /// The feed was unreachable/unparsable, or the versions could not be
        /// compared. Surfaced as *unbekannt*, never as an update.
        case unknown
    }

    /// The comparison outcome.
    public var availability: Availability
    /// The version the running app reports (its `CFBundleShortVersionString`).
    public var currentVersion: String
    /// The newest version the feed advertised, when one could be read — carried
    /// even for ``Availability/upToDate``/``Availability/unknown`` for display.
    public var latestVersion: String?

    public init(
        availability: Availability,
        currentVersion: String,
        latestVersion: String? = nil
    ) {
        self.availability = availability
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
    }

    /// Convenience: `true` only when a concrete newer version is available.
    public var hasUpdate: Bool {
        if case .updateAvailable = availability { return true }
        return false
    }
}

/// Checks whether OpenFreshr has a newer release of *itself*.
///
/// This is the honest-dogfooding core of the Sparkle self-update: it reuses the
/// very same ``SparkleAppcast`` reader and fail-closed ``VersionComparator`` that
/// OpenFreshr applies to the foreign apps it manages. It is deliberately UI-free
/// and fully injectable (feed URL, current version, ``HTTPFetching``) so the
/// self-update decision is unit-testable **without** the Sparkle framework, the
/// network, or a running app.
///
/// The app shell layers the user experience on top: the
/// "Nach OpenFreshr-Updates suchen…" command calls this to tell the user whether
/// a new build exists (and, in the framework-free default build, to open the
/// release page). Once Sparkle is linked for a signed release, Sparkle's own
/// signed-installer flow takes over the actual download-and-replace step, while
/// this type remains the testable version oracle.
public enum SelfUpdateChecker {

    /// Read `feedURL` and compare its newest advertised version against
    /// `currentVersion`.
    ///
    /// - Parameters:
    ///   - currentVersion: the running app's marketing version
    ///     (`CFBundleShortVersionString`).
    ///   - feedURL: the appcast URL (only `http`/`https` are attempted).
    ///   - fetcher: the HTTP transport (injectable for tests).
    /// - Returns: a ``SelfUpdateStatus`` that is never a false positive.
    public static func check(
        currentVersion: String,
        feedURL: String,
        using fetcher: any HTTPFetching
    ) async -> SelfUpdateStatus {
        guard let latest = await SparkleAppcast.fetchNewestVersion(
            feedURL: feedURL,
            using: fetcher
        ) else {
            return SelfUpdateStatus(
                availability: .unknown,
                currentVersion: currentVersion,
                latestVersion: nil
            )
        }

        switch VersionComparator.compare(installed: currentVersion, available: latest) {
        case .older:
            return SelfUpdateStatus(
                availability: .updateAvailable(version: latest),
                currentVersion: currentVersion,
                latestVersion: latest
            )
        case .same, .newer:
            return SelfUpdateStatus(
                availability: .upToDate,
                currentVersion: currentVersion,
                latestVersion: latest
            )
        case .none:
            // A version pair the comparator declines to order (e.g. a marketing
            // tie separated only by a pre-release qualifier) is never an update.
            return SelfUpdateStatus(
                availability: .unknown,
                currentVersion: currentVersion,
                latestVersion: latest
            )
        }
    }
}
