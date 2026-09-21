import Foundation

/// Maps the *real* Homebrew cask API document (`cask.json`) onto the internal
/// ``Cask`` model — and, crucially, populates the bundle-identifier buckets,
/// which no other production code path did before.
///
/// Homebrew casks do not expose a clean "bundle identifier" field. Identity has
/// to be *recovered* from two places, and the two are kept in **separate**
/// buckets because they carry very different trust:
///
/// * the `quit`, `signal`, `launchctl`, `login_item` and `pkgutil` fields of the
///   `uninstall`/`zap` stanzas name the app's *own* launch agents and packages →
///   ``Cask/primaryBundleIdentifiers`` (strong identity); and
/// * bundle identifiers **embedded in cleanup paths** such as
///   `~/Library/Preferences/<id>.plist`,
///   `~/Library/Application Support/<id>` or `~/Library/Containers/<id>`
///   routinely reference *foreign* file debris and are **not** proof of identity
///   → ``Cask/cleanupBundleIdentifiers`` (weak, path-derived).
///
/// Keeping them apart is a safety fix: folding a `trash` path's id into the
/// strong bucket let a cask forge a corroboration for an unrelated installed app
/// (`zap.trash: ~/Library/Containers/<victim-id>`). See ``MatchResolver`` for how
/// each bucket is allowed to be used (corroboration vs. veto).
///
/// The extraction is deliberately conservative: it keeps two-component ids like
/// `md.obsidian`, strips a leading Apple Team ID (`UBF8T346G9.com.foo` → the
/// team prefix is dropped), rejects bundle *folder* names (`OneDrive.app`) while
/// keeping reverse-DNS ids that merely end in `.app` (`com.cmuxterm.app`), and
/// never treats the `com.apple.*` or `group.*` namespaces as identity — those
/// are shared system/containers, not the app the cask installs.
public enum CaskCatalogIngestion {

    // MARK: - Public entry points

    /// Ingest the raw bytes of a Homebrew `cask.json` (an array of cask objects)
    /// into the internal model.
    public static func casks(fromAPIData data: Data) throws -> [Cask] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw IngestionError.unexpectedRootShape
        }
        return array.compactMap { element in
            guard let raw = element as? [String: Any] else { return nil }
            return ingest(raw)
        }
    }

    /// Decode a full ``CaskCatalog`` from raw Homebrew API bytes.
    public static func decodeCatalog(fromAPIData data: Data, fetchedAt: Date) throws -> CaskCatalog {
        CaskCatalog(casks: try casks(fromAPIData: data), fetchedAt: fetchedAt)
    }

    public enum IngestionError: Error {
        case unexpectedRootShape
    }

    // MARK: - Ingestion of one cask

    /// Map a single raw cask object onto ``Cask``.
    static func ingest(_ raw: [String: Any]) -> Cask {
        var artifacts: [CaskArtifact] = []
        // The `uninstall`/`zap` stanza payloads, harvested for identity below.
        var identityStanzas: [Any] = []

        for element in (raw["artifacts"] as? [Any]) ?? [] {
            guard let artifact = element as? [String: Any] else { continue }
            let keys = artifact.keys.filter { $0 != "target" }
            guard let key = preferredArtifactKey(from: keys) else { continue }

            switch key {
            case "app", "suite":
                artifacts.append(
                    CaskArtifact(
                        kind: key == "app" ? .app : .suite,
                        target: appTargetName(in: artifact, key: key)
                    )
                )
            case "pkg":
                artifacts.append(CaskArtifact(kind: .pkg))
            case "installer":
                artifacts.append(CaskArtifact(kind: .installer))
            case "binary":
                artifacts.append(CaskArtifact(kind: .binary))
            case "uninstall", "zap":
                if let payload = artifact[key] { identityStanzas.append(payload) }
                artifacts.append(CaskArtifact(kind: .other(key)))
            default:
                artifacts.append(CaskArtifact(kind: .other(key)))
            }
        }

        var primary = Set<String>()
        var cleanup = Set<String>()
        extractIdentity(from: identityStanzas, primary: &primary, cleanup: &cleanup)
        // A path-derived id that is *also* declared as a strong identity belongs
        // to the cask proper — keep it only in `primary`. What remains in
        // `cleanup` is exactly the set of ids known *only* from cleanup paths.
        cleanup.subtract(primary)

        return Cask(
            token: raw["token"] as? String ?? "",
            names: stringArray(raw["name"]),
            oldTokens: stringArray(raw["old_tokens"]),
            version: raw["version"] as? String,
            autoUpdates: raw["auto_updates"] as? Bool ?? false,
            homepage: raw["homepage"] as? String,
            desc: (raw["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            artifacts: artifacts,
            primaryBundleIdentifiers: primary.sorted(),
            cleanupBundleIdentifiers: cleanup.sorted()
        )
    }

    /// Pick the single artifact-kind key of an artifact dict. Entries in the
    /// Homebrew document carry exactly one artifact key besides `target`; a stable
    /// priority order keeps ingestion deterministic even if that ever changes.
    private static func preferredArtifactKey(from keys: [String]) -> String? {
        let priority = ["app", "suite", "pkg", "installer", "binary", "uninstall", "zap"]
        for candidate in priority where keys.contains(candidate) { return candidate }
        return keys.sorted().first
    }

    /// The moved-artifact target file name, e.g. `Copilot.app`.
    ///
    /// Homebrew places the absolute install target in a sibling `target` key of
    /// the same dict; its last path component is the bundle file name. When that
    /// is absent, the artifact's own array is parsed (a `{"target": …}` entry, or
    /// otherwise the first string).
    static func appTargetName(in artifact: [String: Any], key: String) -> String? {
        if let target = artifact["target"] as? String, !target.isEmpty {
            return lastPathComponent(target)
        }
        guard let values = artifact[key] as? [Any] else { return nil }
        for value in values {
            if let dict = value as? [String: Any], let target = dict["target"] {
                return lastPathComponent(String(describing: target))
            }
        }
        for value in values {
            if let string = value as? String { return string }
        }
        return nil
    }

    // MARK: - Identity extraction

    /// Fields that name the cask's *own* launch agents / packages — i.e. identity.
    private static let identityFields = ["quit", "signal", "launchctl", "login_item", "pkgutil"]
    /// Fields that hold cleanup *paths*, from which embedded ids are recovered.
    private static let pathFields = ["trash", "delete"]

    /// Split a cask's recovered identity into the two buckets the safety model
    /// keeps apart:
    ///
    /// * **strong fields** (`quit`/`signal`/`launchctl`/`login_item`/`pkgutil`)
    ///   name the cask's *own* launch agents and packages → `primary`;
    /// * ids embedded in **cleanup paths** (`trash`/`delete`) routinely point at
    ///   *foreign* file debris and are not proof of identity → `cleanup`.
    ///
    /// Conflating the two is exactly what let a `trash` path forge a corroboration
    /// for an unrelated app; see the type-level documentation.
    private static func extractIdentity(
        from stanzaLists: [Any],
        primary: inout Set<String>,
        cleanup: inout Set<String>
    ) {
        for stanzaList in stanzaLists {
            guard let stanzas = stanzaList as? [Any] else { continue }
            for element in stanzas {
                guard let stanza = element as? [String: Any] else { continue }
                for field in identityFields {
                    if let value = stanza[field] { idsFromValue(value, into: &primary) }
                }
                for field in pathFields {
                    if let value = stanza[field] { pathsFromValue(value, into: &cleanup) }
                }
            }
        }
    }

    /// Collect id-shaped strings from a string or an arbitrarily nested array.
    static func idsFromValue(_ value: Any, into out: inout Set<String>) {
        if let string = value as? String {
            if let id = canonicalBundleID(string) { out.insert(id) }
        } else if let array = value as? [Any] {
            for item in array { idsFromValue(item, into: &out) }
        }
    }

    private static func pathsFromValue(_ value: Any, into out: inout Set<String>) {
        if let string = value as? String {
            idsFromPath(string, into: &out)
        } else if let array = value as? [Any] {
            for item in array { pathsFromValue(item, into: &out) }
        }
    }

    /// Suffixes stripped off a path segment before testing it as an id, so
    /// `md.obsidian.plist` and `com.foo.bar.savedState` reduce to the id.
    private static let pathStripSuffixes = [".plist", ".savedstate", ".sfl", ".json", ".binarycookies", ".log"]

    /// Recover bundle ids embedded in the segments of a cleanup path.
    static func idsFromPath(_ path: String, into out: inout Set<String>) {
        for rawSegment in path.split(separator: "/", omittingEmptySubsequences: true) {
            var segment = rawSegment.trimmingCharacters(in: .whitespaces)
            if segment.hasSuffix("*") { segment.removeLast() }

            var changed = true
            while changed {
                changed = false
                let lower = segment.lowercased()
                for suffix in pathStripSuffixes where lower.hasSuffix(suffix) {
                    segment = String(segment.dropLast(suffix.count))
                    changed = true
                }
            }

            if let id = canonicalBundleID(segment) { out.insert(id) }
        }
    }

    // MARK: - Canonicalisation

    /// A bundle *folder* suffix: a path segment ending in one is a file/bundle
    /// name (`OneDrive.app`) unless it is a reverse-DNS id that merely ends in the
    /// same word (`com.cmuxterm.app`). Only <= 2-component tokens are rejected.
    private static let folderSuffixes = [
        ".app", ".pkg", ".bundle", ".framework", ".kext", ".plugin",
        ".qlgenerator", ".prefpane", ".mdimporter", ".xpc",
    ]

    private static let bundleIDRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9-]*(?:\\.[A-Za-z0-9-]+)+$"
    )
    private static let teamIDRegex = try! NSRegularExpression(pattern: "^[A-Z0-9]{10}$")

    /// Return a clean bundle id for `token`, or `nil` when it is not identity.
    ///
    /// Strips a leading Apple Team ID component, rejects bundle-folder names and
    /// the `com.apple.*`/`group.*` namespaces, and requires at least two
    /// dot-separated components so `md.obsidian` survives but `TERM` does not.
    static func canonicalBundleID(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let dotCount = trimmed.filter { $0 == "." }.count
        if dotCount <= 1 {
            for suffix in folderSuffixes where lower.hasSuffix(suffix) { return nil }
        }

        var parts = trimmed.components(separatedBy: ".")
        if parts.count >= 2, matches(teamIDRegex, parts[0]) {
            parts.removeFirst()
        }
        let candidate = parts.joined(separator: ".")
        guard matches(bundleIDRegex, candidate) else { return nil }

        let candidateLower = candidate.lowercased()
        if candidateLower.hasPrefix("com.apple.") || candidateLower.hasPrefix("group.") {
            return nil
        }
        return candidate
    }

    // MARK: - Small helpers

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
