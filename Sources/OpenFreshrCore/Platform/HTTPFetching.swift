import Foundation

/// Minimal async HTTP GET used to refresh the cask catalog.
///
/// The unconditional ``data(from:)`` primitive backs the Sparkle-feed probes.
/// The conditional ``conditionalGet(_:)`` variant backs the catalog refresh: the
/// Homebrew `cask.json` is ~18 MB, so re-downloading an unchanged document on
/// every launch would be wasteful. Passing the previously stored `ETag` /
/// `Last-Modified` validators lets the server answer `304 Not Modified`, in
/// which case the cache stays valid and only its check date moves.
public protocol HTTPFetching: Sendable {
    /// Fetch the raw bytes at `url`. Throws on transport or non-2xx errors.
    func data(from url: URL) async throws -> Data

    /// Conditionally fetch `request.url`, sending any supplied validators.
    ///
    /// Returns ``ConditionalResponse/notModified`` when the server replies `304`
    /// (the caller keeps its cached bytes), or ``ConditionalResponse/modified``
    /// with fresh bytes and the response's own validators otherwise. Throws on a
    /// transport error or an unexpected non-2xx/304 status, so a failed refresh is
    /// always distinguishable from an up-to-date one.
    func conditionalGet(_ request: ConditionalRequest) async throws -> ConditionalResponse
}

public extension HTTPFetching {
    /// Default: fall back to an unconditional fetch. A fetcher that only knows how
    /// to do a plain GET (e.g. the Sparkle test double) still conforms, always
    /// reporting the body as freshly ``ConditionalResponse/modified`` with no
    /// validators — correct, just never able to benefit from a `304`.
    func conditionalGet(_ request: ConditionalRequest) async throws -> ConditionalResponse {
        let data = try await data(from: request.url)
        return .modified(data: data, validators: CatalogValidators())
    }
}

/// The cache validators carried by a conditional request and echoed by a fresh
/// response. Either may be absent; a first-ever fetch sends neither.
public struct CatalogValidators: Sendable, Equatable, Codable {
    /// The strong `ETag` validator, sent back as `If-None-Match`.
    public var etag: String?
    /// The `Last-Modified` date, sent back as `If-Modified-Since`.
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    /// `true` when neither validator is present, so a conditional request would
    /// degrade to an unconditional one.
    public var isEmpty: Bool { etag == nil && lastModified == nil }
}

/// A conditional GET: a URL plus the validators last seen for that resource.
public struct ConditionalRequest: Sendable, Equatable {
    public var url: URL
    public var validators: CatalogValidators

    public init(url: URL, validators: CatalogValidators = CatalogValidators()) {
        self.url = url
        self.validators = validators
    }
}

/// The outcome of a ``HTTPFetching/conditionalGet(_:)``.
public enum ConditionalResponse: Sendable, Equatable {
    /// The server answered `304`; the caller's cached bytes are still current.
    case notModified
    /// The server returned fresh bytes and (best-effort) their new validators.
    case modified(data: Data, validators: CatalogValidators)
}

/// Error thrown when an HTTP response is not a 2xx status.
public struct HTTPStatusError: Error, Sendable {
    public var statusCode: Int
    public init(statusCode: Int) { self.statusCode = statusCode }
}

/// Error thrown when a response body exceeds the accepted size ceiling.
///
/// The PRD requires network responses to be processed with explicit size limits;
/// this keeps a hostile or misconfigured endpoint from streaming an unbounded
/// body into memory during a catalog refresh.
public struct HTTPBodyTooLargeError: Error, Sendable {
    public var byteCount: Int
    public var limit: Int
    public init(byteCount: Int, limit: Int) {
        self.byteCount = byteCount
        self.limit = limit
    }
}

/// `URLSession`-backed implementation.
public struct SystemHTTPFetcher: HTTPFetching {
    private let session: URLSession
    private let timeout: TimeInterval
    private let maximumBodyBytes: Int

    /// - Parameters:
    ///   - session: the session to use (default: `.shared`).
    ///   - timeout: per-request time limit; the full `cask.json` is large but a
    ///     stalled connection must never hang a refresh (default: 60 s).
    ///   - maximumBodyBytes: hard ceiling on an accepted body. The catalog is
    ///     ~18 MB and analytics ~2 MB, so 128 MB leaves ample headroom while still
    ///     rejecting a pathological response (default: 128 MB).
    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 60,
        maximumBodyBytes: Int = 128 * 1_024 * 1_024
    ) {
        self.session = session
        self.timeout = timeout
        self.maximumBodyBytes = maximumBodyBytes
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(for: url, validators: CatalogValidators()))
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
        try enforceBodyLimit(data)
        return data
    }

    public func conditionalGet(_ conditional: ConditionalRequest) async throws -> ConditionalResponse {
        let (data, response) = try await session.data(
            for: request(for: conditional.url, validators: conditional.validators)
        )
        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP response has no status to reason about; treat its bytes as
            // fresh rather than inventing a 304.
            try enforceBodyLimit(data)
            return .modified(data: data, validators: CatalogValidators())
        }
        if http.statusCode == 304 {
            return .notModified
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
        try enforceBodyLimit(data)
        return .modified(data: data, validators: Self.validators(from: http))
    }

    /// Build a GET carrying the supplied validators as conditional headers.
    private func request(for url: URL, validators: CatalogValidators) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // Homebrew serves gzip; asking for it keeps the 18 MB catalog transfer down.
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    private func enforceBodyLimit(_ data: Data) throws {
        if data.count > maximumBodyBytes {
            throw HTTPBodyTooLargeError(byteCount: data.count, limit: maximumBodyBytes)
        }
    }

    /// Read the `ETag` / `Last-Modified` validators off a fresh response so they
    /// can be stored and replayed on the next refresh.
    private static func validators(from http: HTTPURLResponse) -> CatalogValidators {
        CatalogValidators(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}
