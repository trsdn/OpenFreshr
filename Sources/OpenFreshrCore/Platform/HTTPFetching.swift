import Foundation

/// Minimal async HTTP GET used to refresh the cask catalog.
///
/// Phase 1 works entirely offline from a cached/bundled catalog, so this
/// protocol exists mainly to keep the network boundary injectable and to let a
/// later phase fetch the live Homebrew API without reaching into `URLSession`
/// from the middle of the catalog code.
public protocol HTTPFetching: Sendable {
    /// Fetch the raw bytes at `url`. Throws on transport or non-2xx errors.
    func data(from url: URL) async throws -> Data
}

/// Error thrown when an HTTP response is not a 2xx status.
public struct HTTPStatusError: Error, Sendable {
    public var statusCode: Int
    public init(statusCode: Int) { self.statusCode = statusCode }
}

/// `URLSession`-backed implementation.
public struct SystemHTTPFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
        return data
    }
}
