import Foundation
@testable import OpenFreshrCore

/// A programmable ``HTTPFetching`` for Sparkle-feed *and* catalog-refresh tests.
///
/// It maps a URL string to either bytes or an error, records every request, and
/// — crucially — lets a test model the outcomes each caller must distinguish:
///
/// * for Sparkle feeds via ``data(from:)``: a reachable feed with a version, a
///   reachable-but-unparsable feed, and a transport failure (an unmapped URL
///   throws); and
/// * for the catalog refresh via ``conditionalGet(_:)``: a fresh body with
///   validators, a `304 Not Modified`, and a transport failure — optionally as a
///   *queue* so one URL can answer "fresh" then "not modified" across two
///   refreshes.
///
/// `@unchecked Sendable`: mutable state is serialised behind a lock.
final class FakeHTTPFetcher: HTTPFetching, @unchecked Sendable {

    struct MissingResponseError: Error, Sendable { let url: String }

    private let lock = NSLock()
    private var responses: [String: Result<Data, TransportError>]
    private var _requestedURLs: [String] = []

    /// Scripted conditional outcomes, per URL, consumed front-to-back. When empty
    /// for a URL, ``conditionalGet(_:)`` falls back to the plain ``responses`` map.
    private var conditionalQueues: [String: [ConditionalOutcome]] = [:]
    /// The conditional requests seen so far, so a test can assert which validators
    /// were replayed (e.g. that the stored `ETag` was sent on the second refresh).
    private var _conditionalRequests: [ConditionalRequest] = []

    /// A stand-in transport error for an unreachable feed/endpoint.
    struct TransportError: Error, Sendable { var message: String }

    /// One scripted answer to a conditional GET.
    enum ConditionalOutcome: Sendable {
        case modified(Data, CatalogValidators)
        case notModified
        case failure(TransportError)
    }

    init(responses: [String: Result<Data, TransportError>] = [:]) {
        self.responses = responses
    }

    /// URLs requested so far, in order.
    var requestedURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestedURLs
    }

    /// Conditional requests seen so far, in order.
    var conditionalRequests: [ConditionalRequest] {
        lock.lock(); defer { lock.unlock() }
        return _conditionalRequests
    }

    /// Map `url` to raw bytes (used by ``data(from:)`` and as the conditional
    /// fallback when no outcome is queued).
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

    /// Append a scripted conditional outcome for `url`. Successive refreshes of the
    /// same URL consume these in order.
    func enqueueConditional(_ outcome: ConditionalOutcome, for url: String) {
        lock.lock(); defer { lock.unlock() }
        conditionalQueues[url, default: []].append(outcome)
    }

    /// Convenience: script a single fresh body with validators for `url`.
    func setConditionalModified(_ data: Data, validators: CatalogValidators, for url: String) {
        enqueueConditional(.modified(data, validators), for: url)
    }

    /// Convenience: script a single `304 Not Modified` for `url`.
    func setConditionalNotModified(for url: String) {
        enqueueConditional(.notModified, for: url)
    }

    /// Convenience: script a single transport failure for `url`.
    func setConditionalFailure(_ message: String, for url: String) {
        enqueueConditional(.failure(TransportError(message: message)), for: url)
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

    func conditionalGet(_ request: ConditionalRequest) async throws -> ConditionalResponse {
        switch recordConditional(request) {
        case let .modified(data, validators):
            return .modified(data: data, validators: validators)
        case .notModified:
            return .notModified
        case let .failure(error):
            throw error
        }
    }

    /// Synchronous critical section: record the request and read its mapping.
    /// Kept non-`async` so the lock is never held across a suspension point.
    private func record(_ url: URL) -> Result<Data, TransportError>? {
        lock.lock(); defer { lock.unlock() }
        _requestedURLs.append(url.absoluteString)
        return responses[url.absoluteString]
    }

    /// Resolve a conditional GET: consume a queued outcome if present, else fall
    /// back to the plain ``responses`` mapping (success → fresh, failure → throw,
    /// unmapped → throw). Records the request under the lock.
    private func recordConditional(_ request: ConditionalRequest) -> ConditionalOutcome {
        lock.lock(); defer { lock.unlock() }
        let key = request.url.absoluteString
        _requestedURLs.append(key)
        _conditionalRequests.append(request)
        if var queue = conditionalQueues[key], !queue.isEmpty {
            let outcome = queue.removeFirst()
            conditionalQueues[key] = queue
            return outcome
        }
        switch responses[key] {
        case let .success(data):
            return .modified(data, CatalogValidators())
        case let .failure(error):
            return .failure(error)
        case .none:
            return .failure(TransportError(message: "no response mapped for \(key)"))
        }
    }
}
