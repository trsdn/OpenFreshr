import Foundation

/// Why a stored team ID is trusted.
public enum TrustOrigin: String, Sendable, Codable, Hashable {
    /// The team ID was captured the first time OpenFreshr ever saw this bundle —
    /// classic trust-on-first-use. **This is a baseline, not a guarantee:** if the
    /// very first install was already compromised, its team ID is what gets
    /// trusted. The UI states this limitation plainly rather than implying more.
    case firstUse
    /// The user explicitly confirmed a team-ID change through the opt-in flow, and
    /// this team ID replaced the previous baseline.
    case userConfirmedChange
}

/// A single, explicitly confirmed team-ID change, kept for the audit trail so a
/// past decision to accept a new publisher stays visible and reviewable.
public struct TrustChange: Sendable, Hashable, Codable {
    public var previousTeamIdentifier: String
    public var newTeamIdentifier: String
    public var confirmedAt: Date

    public init(previousTeamIdentifier: String, newTeamIdentifier: String, confirmedAt: Date) {
        self.previousTeamIdentifier = previousTeamIdentifier
        self.newTeamIdentifier = newTeamIdentifier
        self.confirmedAt = confirmedAt
    }
}

/// The persisted trust baseline for one bundle identifier.
public struct TrustRecord: Sendable, Hashable, Codable, Identifiable {
    /// The bundle identifier this record anchors, e.g. `com.google.chrome`.
    public var bundleIdentifier: String
    /// The team ID currently trusted for this bundle.
    public var teamIdentifier: String
    /// When the baseline was first established.
    public var firstObservedAt: Date
    /// When the record last changed (first-use or a confirmed change).
    public var updatedAt: Date
    /// Whether the trust originates from first use or a confirmed change.
    public var origin: TrustOrigin
    /// The log of explicitly confirmed team-ID changes, oldest first.
    public var confirmedChanges: [TrustChange]

    public init(
        bundleIdentifier: String,
        teamIdentifier: String,
        firstObservedAt: Date,
        updatedAt: Date,
        origin: TrustOrigin,
        confirmedChanges: [TrustChange] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.firstObservedAt = firstObservedAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.confirmedChanges = confirmedChanges
    }

    public var id: String { bundleIdentifier }
}

/// Persists observed team IDs per bundle identifier so a later publisher change
/// can be detected.
///
/// Behind a protocol so the trust gate never touches the disk in tests: the
/// suite drives an ``InMemoryTrustStore`` while the app writes a small JSON file
/// under Application Support. Implementations are responsible for their own
/// thread-safety; every method is synchronous and total.
public protocol TrustStoring: Sendable {
    /// The stored record for `bundleIdentifier`, or `nil` when never observed.
    func record(for bundleIdentifier: String) -> TrustRecord?
    /// Every stored record, for the trust-management UI. Order is unspecified.
    func allRecords() -> [TrustRecord]
    /// Insert or replace the record for its bundle identifier.
    func save(_ record: TrustRecord)
    /// Forget the baseline for one bundle identifier. The next observation of that
    /// bundle is a fresh first-use, **not** implicit re-trust of the old team.
    func reset(bundleIdentifier: String)
    /// Forget every stored decision.
    func resetAll()
}

/// An in-memory ``TrustStoring`` for tests and previews. Thread-safe via a lock
/// so it can be shared by the `Sendable` coordinators without data races.
public final class InMemoryTrustStore: TrustStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var records: [String: TrustRecord]

    public init(records: [TrustRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.bundleIdentifier, $0) })
    }

    public func record(for bundleIdentifier: String) -> TrustRecord? {
        lock.withLock { records[bundleIdentifier] }
    }

    public func allRecords() -> [TrustRecord] {
        lock.withLock { Array(records.values) }
    }

    public func save(_ record: TrustRecord) {
        lock.withLock { records[record.bundleIdentifier] = record }
    }

    public func reset(bundleIdentifier: String) {
        lock.withLock { _ = records.removeValue(forKey: bundleIdentifier) }
    }

    public func resetAll() {
        lock.withLock { records.removeAll() }
    }
}

/// A JSON-file-backed ``TrustStoring`` for the app.
///
/// Writes a single human-readable JSON array to a URL (in the app this lives in
/// `~/Library/Application Support/OpenFreshr/`). It loads once on init and
/// rewrites the whole file on each mutation — the data set is tiny (one line per
/// managed app) so simplicity wins over incremental writes. A missing or corrupt
/// file starts empty rather than crashing; trust decisions are recoverable, and
/// losing them degrades to a fresh first-use, never to a false "trusted".
public final class JSONFileTrustStore: TrustStoring, @unchecked Sendable {

    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var records: [String: TrustRecord]

    /// The default on-disk location: `Application Support/OpenFreshr/trust-store.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base =
            (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return
            base
            .appendingPathComponent("OpenFreshr", isDirectory: true)
            .appendingPathComponent("trust-store.json", isDirectory: false)
    }

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.records = Self.load(from: url, fileManager: fileManager)
    }

    public convenience init(fileManager: FileManager = .default) {
        self.init(url: Self.defaultURL(fileManager: fileManager), fileManager: fileManager)
    }

    public func record(for bundleIdentifier: String) -> TrustRecord? {
        lock.withLock { records[bundleIdentifier] }
    }

    public func allRecords() -> [TrustRecord] {
        lock.withLock { Array(records.values) }
    }

    public func save(_ record: TrustRecord) {
        lock.withLock {
            records[record.bundleIdentifier] = record
            persist()
        }
    }

    public func reset(bundleIdentifier: String) {
        lock.withLock {
            records.removeValue(forKey: bundleIdentifier)
            persist()
        }
    }

    public func resetAll() {
        lock.withLock {
            records.removeAll()
            persist()
        }
    }

    // MARK: - Disk

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func load(from url: URL, fileManager: FileManager) -> [String: TrustRecord] {
        guard fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let decoded = try? decoder().decode([TrustRecord].self, from: data)
        else {
            return [:]
        }
        return Dictionary(decoded.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Must be called with `lock` held.
    private func persist() {
        let sorted = records.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        guard let data = try? Self.encoder().encode(sorted) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
