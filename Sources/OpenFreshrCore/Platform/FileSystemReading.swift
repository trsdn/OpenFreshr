import Foundation

/// Read-only filesystem access needed by the inventory scan.
///
/// Every filesystem touch in the core goes through this protocol so tests can
/// feed a synthetic `/Applications` from fixtures. No method mutates the disk —
/// OpenFreshr's scan is strictly observational, and the type system says so.
public protocol FileSystemReading: Sendable {

    /// Immediate children of `directory` (non-recursive). Returns absolute paths.
    /// Throws when the directory cannot be read; callers decide whether that is
    /// fatal (it is not, for a single scan root).
    func contentsOfDirectory(atPath directory: String) throws -> [String]

    /// `true` when a file or directory exists at `path`.
    func fileExists(atPath path: String) -> Bool

    /// Raw bytes of the file at `path`, e.g. an `Info.plist`. Throws when absent
    /// or unreadable.
    func contents(ofFile path: String) throws -> Data
}

/// `FileManager`-backed implementation used by the app.
///
/// Marked `@unchecked Sendable` because `Foundation.FileManager` is not
/// annotated `Sendable`, yet the read-only operations used here are safe to call
/// from any thread and the struct holds no mutable state.
public struct SystemFileSystem: FileSystemReading, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func contentsOfDirectory(atPath directory: String) throws -> [String] {
        try fileManager
            .contentsOfDirectory(atPath: directory)
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    public func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func contents(ofFile path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
