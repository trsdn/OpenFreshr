import Foundation

/// The inventory scan, reduced to the one capability the coordinators depend on.
///
/// ``AdoptionCoordinator`` and ``UpdateCoordinator`` only ever ask for "the apps
/// in these directories". Expressing that as a protocol lets a test inject a
/// scripted scanner that returns a different inventory before and after an
/// update — which is exactly how the "success only after rescan" contract is
/// exercised without touching a real disk. The production ``InventoryScanner``
/// conforms unchanged.
public protocol Scanning: Sendable {
    func scan(directories: [String]) -> [InstalledApp]
}

extension InventoryScanner: Scanning {}
