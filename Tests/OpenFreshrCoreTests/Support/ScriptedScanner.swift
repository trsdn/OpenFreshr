import Foundation
@testable import OpenFreshrCore

/// A ``Scanning`` that replays scripted inventories, one per scan call.
///
/// This is what makes the "success only after rescan" contract testable: a test
/// hands the coordinator a *before* inventory (the app at its old version) and
/// an *after* inventory (the app at its new version, or gone from the outdated
/// list). The first ``scan(directories:)`` returns the first snapshot, the next
/// returns the second, and once the script is exhausted the last snapshot is
/// repeated so any extra rescans stay consistent.
///
/// `@unchecked Sendable`: the cursor and call log are serialised behind a lock.
final class ScriptedScanner: Scanning, @unchecked Sendable {

    private let lock = NSLock()
    private let snapshots: [[InstalledApp]]
    private var cursor = 0
    private var _scanCount = 0

    /// - Parameter snapshots: One inventory per expected scan. Must be non-empty.
    init(snapshots: [[InstalledApp]]) {
        precondition(!snapshots.isEmpty, "ScriptedScanner needs at least one snapshot")
        self.snapshots = snapshots
    }

    /// Convenience for a scanner that always returns the same inventory.
    convenience init(apps: [InstalledApp]) {
        self.init(snapshots: [apps])
    }

    /// How many times ``scan(directories:)`` has been called.
    var scanCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _scanCount
    }

    func scan(directories: [String]) -> [InstalledApp] {
        lock.lock(); defer { lock.unlock() }
        _scanCount += 1
        let snapshot = snapshots[min(cursor, snapshots.count - 1)]
        if cursor < snapshots.count - 1 { cursor += 1 }
        return snapshot
    }
}
