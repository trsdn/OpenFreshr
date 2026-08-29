import Foundation
@testable import OpenFreshrCore

/// A programmable ``HTTPFetching`` for Sparkle-feed tests.
///
/// It maps a URL string to either bytes or an error, records every request, and
/// — crucially — lets a test model the three feed outcomes the resolver must
/// distinguish: a reachable feed with a version, a reachable-but-unparsable
/// feed, and a transport failure (a URL with no mapping throws).
///
/// `@unchecked Sendable`: mutable state is serialised behind a lock.
final class FakeHTTPFetcher: HTTPFetching, @unchecked Sendable {

    struct MissingResponseError: Error, Sendable { let url: String }

    private let lock = NSLock()
    private var responses: [String: Result<Data, TransportError>]
    private var _requestedURLs: [String] = []

    /// A stand-in transport error for an unreachable feed.
    struct TransportError: Error, Sendable { var message: String }

    init(responses: [String: Result<Data, TransportError>] = [:]) {
        self.responses = responses
    }

    /// URLs requested so far, in order.
    var requestedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestedURLs
    }

    /// Map `url` to raw bytes.
    func setData(_ data: Data, for url: String) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = .success(data)
    }

    /// Map `url` to a UTF-8 string body.
    func setBody(_ body: String, for url: String) {
        setData(Data(body.utf8), for: url)
    }

    /// Map `url` to a transport failure.
    func setFailure(_ message: String, for url: String) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = .failure(TransportError(message: message))
    }

    func data(from url: URL) async throws -> Data {
        switch record(url) {
        case let .success(data):
            return data
        case let .failure(error):
            throw error
        case .none:
            throw MissingResponseError(url: url.absoluteString)
        }
    }

    /// Synchronous critical section: record the request and read its mapping.
    /// Kept non-`async` so the lock is never held across a suspension point.
    private func record(_ url: URL) -> Result<Data, TransportError>? {
        lock.lock(); defer { lock.unlock() }
        _requestedURLs.append(url.absoluteString)
        return responses[url.absoluteString]
    }
}
