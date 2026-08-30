import Foundation

/// Persistence for "when did the last successful background update check finish".
///
/// Only one fact is stored, but it is the fact the whole schedule turns on: it is
/// what makes ``UpdateCheckSchedule/isDue(lastSuccessfulCheck:now:)`` answer
/// truthfully across launches, so a restart does not immediately re-scan. The
/// boundary is a protocol for the same reason every I/O boundary in OpenFreshr
/// is: the app writes JSON to `Application Support`, tests use an in-memory
/// double and never touch disk.
public protocol LastCheckStoring: Sendable {

    /// The instant the last successful background check completed, or `nil` if
    /// one never has.
    func lastSuccessfulCheck() -> Date?

    /// Record that a successful check completed at `date`.
    func recordSuccessfulCheck(at date: Date)

    /// Forget the recorded time, so the next evaluation behaves as "never
    /// checked". Used by tests and, potentially, a "reset" affordance.
    func clear()
}

/// An in-memory ``LastCheckStoring`` for tests and previews.
///
/// It can be seeded with an initial date so a test can express "the last check
/// was N seconds ago" without any real waiting.
public final class InMemoryLastCheckStore: LastCheckStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var date: Date?

    public init(lastSuccessfulCheck: Date? = nil) {
        self.date = lastSuccessfulCheck
    }

    public func lastSuccessfulCheck() -> Date? {
        lock.withLock { date }
    }

    public func recordSuccessfulCheck(at date: Date) {
        lock.withLock { self.date = date }
    }

    public func clear() {
        lock.withLock { date = nil }
    }
}

/// A JSON-file-backed ``LastCheckStoring`` for the app.
///
/// Mirrors ``JSONFileTrustStore``: a single tiny JSON object at a URL (in the app
/// `~/Library/Application Support/OpenFreshr/last-check.json`), loaded once on
/// init and rewritten on each update. A missing or corrupt file reads as "never
/// checked", which is the safe default — at worst OpenFreshr checks once more
/// than strictly necessary, it never wrongly believes it already checked.
public final class JSONFileLastCheckStore: LastCheckStoring, @unchecked Sendable {

    private struct Payload: Codable {
        var lastSuccessfulCheck: Date?
    }

    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var date: Date?

    /// The default on-disk location:
    /// `Application Support/OpenFreshr/last-check.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenFreshr", isDirectory: true)
            .appendingPathComponent("last-check.json", isDirectory: false)
    }

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.date = Self.load(from: url, fileManager: fileManager)
    }

    public convenience init(fileManager: FileManager = .default) {
        self.init(url: Self.defaultURL(fileManager: fileManager), fileManager: fileManager)
    }

    public func lastSuccessfulCheck() -> Date? {
        lock.withLock { date }
    }

    public func recordSuccessfulCheck(at date: Date) {
        lock.withLock {
            self.date = date
            persist()
        }
    }

    public func clear() {
        lock.withLock {
            date = nil
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

    private static func load(from url: URL, fileManager: FileManager) -> Date? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        return decoded.lastSuccessfulCheck
    }

    /// Must be called with `lock` held.
    private func persist() {
        guard let data = try? Self.encoder().encode(Payload(lastSuccessfulCheck: date)) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
