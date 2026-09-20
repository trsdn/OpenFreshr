import Foundation

/// The ordering of an installed version relative to an available one.
///
/// Deliberately three-valued and paired with an *optional* return from
/// ``VersionComparator/compare(installed:available:)``: the fourth outcome —
/// "cannot be compared" — is expressed as `nil`, never as a case here, so a
/// caller can never accidentally treat an incomparable pair as an update.
public enum VersionOrder: String, Sendable, Equatable {
    /// The installed version is behind the available one — an update exists.
    case older
    /// The two versions are equal — up to date.
    case same
    /// The installed version is ahead of the available one (e.g. a pre-release
    /// or a locally newer build) — no update.
    case newer
}

/// Compares software version strings with the one rule that matters here:
/// **an ambiguous comparison is never an update.**
///
/// OpenFreshr replaces apps in place, so a *false* "update available" is the
/// expensive error — it triggers an unnecessary reinstall. Every method is
/// therefore fail-closed: anything the parser cannot line up with confidence
/// yields `nil` (→ *unbekannt*), and only an unambiguous "installed < available"
/// is ever reported as ``VersionOrder/older``.
///
/// The parser normalises the schemes seen in real Homebrew casks and macOS
/// bundles:
///
/// * dotted numeric — `1.2.3`, `11.5.0`
/// * date-like — `2026.8.1` (compared numerically like any other release)
/// * leading zeros — `02.08.02.61` (`02` parses as `2`)
/// * Homebrew `version,revision` — `5.7.3,2320` (marketing part vs revision part
///   kept separate; a non-numeric revision such as a git SHA in
///   `1.40609.0,f65e…` is simply ignored rather than mis-ordered)
/// * build/pre-release suffixes — `1.2.3 (456)`, `1.2.3-457`, `v1.2.3`
///
/// Cross-scheme comparison (a date-versioned string against a semver one) is
/// only meaningful because comparison always runs *within a matched app+cask
/// pair*, which the matching layer guarantees share a scheme; the comparator
/// does not attempt to detect a scheme mismatch a correct match cannot produce.
public enum VersionComparator {

    /// Compare an `installed` version against an `available` one.
    ///
    /// - Returns: ``VersionOrder/older`` when an update exists, ``same`` when up
    ///   to date, ``newer`` when the installed copy is ahead, or `nil` when the
    ///   pair cannot be compared with confidence (missing, non-numeric, or a
    ///   marketing tie that only a pre-release qualifier separates).
    public static func compare(installed: String, available: String) -> VersionOrder? {
        guard let a = parse(installed), let b = parse(available) else { return nil }

        switch compareReleases(a.release, b.release) {
        case .older:
            return .older
        case .newer:
            return .newer
        case .same:
            // The marketing versions are equal. A pre-release qualifier on either
            // side (e.g. `1.2.3-beta` vs `1.2.3`) cannot be ordered safely, so we
            // decline rather than guess a direction.
            if a.hasQualifier || b.hasQualifier { return nil }
            // Both marketing versions are clean and equal. Only a Homebrew
            // revision can still separate them, and only when both are numeric.
            if let ra = a.revision, let rb = b.revision {
                return compareReleases(ra, rb)
            }
            return .same
        }
    }

    /// Whether moving from `installed` to `available` changes the **first**
    /// version component — the definition of a major upgrade here.
    ///
    /// Returns `false` whenever either side is unparseable, so a major upgrade is
    /// only ever asserted about two versions that genuinely compare.
    public static func isMajorChange(from installed: String, to available: String) -> Bool {
        guard let a = parse(installed), let b = parse(available),
              let first = a.release.first, let second = b.release.first else {
            return false
        }
        return first != second
    }

    // MARK: - Parsing

    /// A version split into its comparable pieces.
    private struct Parsed {
        /// Numeric prefix of the marketing version, e.g. `[5, 7, 3]`.
        var release: [Int]
        /// A non-numeric qualifier (`beta`, `rc`, a build letter …) terminated the
        /// marketing version before it was fully numeric.
        var hasQualifier: Bool
        /// Numeric Homebrew revision (post-comma), when present and numeric.
        var revision: [Int]?
    }

    /// Parse a raw version string, or return `nil` when it carries no usable
    /// numeric release at all (empty, `latest`, `:latest`, pure text).
    private static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        // Homebrew's placeholder for an unversioned cask is not a version.
        guard lower != "latest", lower != ":latest" else { return nil }

        // Homebrew encodes `marketing,revision`. Split on the first comma only.
        let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)

        guard let primary = parseRelease(parts[0]) else { return nil }

        var revision: [Int]?
        if parts.count > 1, let rev = parseRelease(parts[1]), !rev.hasQualifier {
            // A revision is only usable when it is purely numeric; a git SHA
            // (`f65e386…`) parses to nothing here and is deliberately dropped.
            revision = rev.release
        }

        return Parsed(release: primary.release, hasQualifier: primary.hasQualifier, revision: revision)
    }

    /// Parse one dotted release token into its leading numeric components.
    ///
    /// Build/pre-release separators (` ( ) _ - + /`) are folded to `.` so
    /// `1.2.3 (456)` and `1.2.3-456` normalise to `1.2.3.456`. Collection stops at
    /// the first non-numeric field, and `hasQualifier` records that a suffix like
    /// `beta` was present so the caller can refuse a marketing tie.
    private static func parseRelease(_ token: String) -> (release: [Int], hasQualifier: Bool)? {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("v") { value.removeFirst() }

        for separator in [" ", "(", ")", "_", "-", "+", "/"] {
            value = value.replacingOccurrences(of: separator, with: ".")
        }

        var release: [Int] = []
        var hasQualifier = false
        for field in value.split(separator: ".", omittingEmptySubsequences: true) {
            let string = String(field)
            if isAllASCIIDigits(string), let number = Int(string) {
                release.append(number)
            } else {
                // A field with letters (or an integer too large to represent)
                // ends the numeric release and marks a qualifier.
                hasQualifier = true
                break
            }
        }

        guard !release.isEmpty else { return nil }
        return (release, hasQualifier)
    }

    /// `true` when every character is an ASCII `0`–`9`. Stricter than
    /// `Character.isNumber`, which also accepts superscripts and other digits.
    private static func isAllASCIIDigits(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// Compare two numeric release vectors, right-padding the shorter with zeros
    /// (`1.2` == `1.2.0`). Always definite — two integer vectors always order.
    private static func compareReleases(_ a: [Int], _ b: [Int]) -> VersionOrder {
        let count = max(a.count, b.count)
        for index in 0..<count {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left < right { return .older }
            if left > right { return .newer }
        }
        return .same
    }
}
