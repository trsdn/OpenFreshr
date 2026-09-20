import Foundation

/// The kind of a Homebrew cask artifact, restricted to what phase 1 reasons
/// about.
///
/// The distinction that matters for adoption is **moved vs. not moved**.
/// `--adopt` only ever acts on `Moved` artifacts (`app`, `suite`): those are
/// relocated in place, so an existing bundle can be taken over losslessly. A
/// `pkg`/`installer` cask instead runs an installer (with a `sudo` prompt that
/// blocks from a GUI process) and is therefore never a safe adoption target.
public enum CaskArtifactKind: Hashable, Sendable, Codable {
    case app
    case suite
    case pkg
    case installer
    case binary
    /// Any other stanza (`font`, `manpage`, `zap`-only, …) we do not act on.
    case other(String)

    /// `true` for artifacts Homebrew relocates in place, the only kind `--adopt`
    /// can take over.
    public var isMovedArtifact: Bool {
        switch self {
        case .app, .suite: return true
        case .pkg, .installer, .binary, .other: return false
        }
    }

    private var rawValue: String {
        switch self {
        case .app: return "app"
        case .suite: return "suite"
        case .pkg: return "pkg"
        case .installer: return "installer"
        case .binary: return "binary"
        case let .other(value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "app": self = .app
        case "suite": self = .suite
        case "pkg": self = .pkg
        case "installer": self = .installer
        case "binary": self = .binary
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A single artifact stanza of a cask: its kind plus, for moved artifacts, the
/// target bundle file name (e.g. `Copilot.app`).
public struct CaskArtifact: Hashable, Sendable, Codable {
    public var kind: CaskArtifactKind
    /// Target file name for `app`/`suite` artifacts, e.g. `Visual Studio Code.app`.
    /// `nil` for `pkg`/`installer` and other non-moved stanzas.
    public var target: String?

    public init(kind: CaskArtifactKind, target: String? = nil) {
        self.kind = kind
        self.target = target
    }
}
