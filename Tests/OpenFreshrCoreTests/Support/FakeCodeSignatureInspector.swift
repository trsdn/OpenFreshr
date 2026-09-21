import Foundation

@testable import OpenFreshrCore

/// A ``CodeSignatureInspecting`` that returns programmed signature facts per
/// bundle path, so the trust gate and coordinators can be exercised without
/// running real `codesign`/`spctl` or touching any bundle on disk.
///
/// `@unchecked Sendable`: the map is immutable after construction and only read.
final class FakeCodeSignatureInspector: CodeSignatureInspecting, @unchecked Sendable {

    private let infos: [String: CodeSignatureInfo]
    private let fallback: CodeSignatureInfo

    /// - Parameters:
    ///   - infos: Signature facts keyed by `bundlePath`.
    ///   - fallback: Returned for any path not in `infos`. Defaults to a verified,
    ///     Gatekeeper-accepted bundle with no readable team ID (an anonymous but
    ///     valid app) so unrelated apps in a batch never accidentally block.
    init(
        infos: [String: CodeSignatureInfo],
        fallback: CodeSignatureInfo = CodeSignatureInfo(
            teamIdentifier: nil, verification: .verified, gatekeeper: .accepted
        )
    ) {
        self.infos = infos
        self.fallback = fallback
    }

    /// Convenience: a single verified app at `bundlePath` signed by `teamIdentifier`.
    static func verified(_ bundlePath: String, team teamIdentifier: String?) -> FakeCodeSignatureInspector {
        FakeCodeSignatureInspector(infos: [
            bundlePath: CodeSignatureInfo(
                teamIdentifier: teamIdentifier, verification: .verified, gatekeeper: .accepted
            )
        ])
    }

    func inspect(bundlePath: String) -> CodeSignatureInfo {
        infos[bundlePath] ?? fallback
    }
}
