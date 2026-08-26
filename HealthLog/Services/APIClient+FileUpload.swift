import Foundation

// MARK: - Plan 09-02 — the one-shot, from-file transport

/// Delegate for the one-shot upload session.
///
/// It does exactly two things, and the second is the reason it exists.
///
/// **It keeps the pin contract.** Server-trust challenges are forwarded
/// verbatim to a ``PinningDelegate``, so this session applies the identical
/// SPKI decision the patient / fail-fast / streaming sessions do. A new session
/// that quietly dropped to default trust handling would be a silent
/// downgrade on the one route that carries the user's entire health archive.
///
/// **It refuses every redirect.** `URLSession`'s default disposition is to
/// follow a 3xx, and for an upload task that means **re-sending the body** —
/// 1.5 GiB, to an address the server chose, without the caller learning that it
/// happened. `nil` from the redirect disposition tells Foundation to stop and
/// hand the redirect response back as the final response, so exactly one wire
/// request leaves the device and the 3xx surfaces as a typed server error the
/// user can be told about.
///
/// Blanket refusal rather than a same-origin allowance, deliberately: a
/// same-origin redirect is still a second transmission of the same body, and
/// the endpoint this route talks to does not redirect. If it ever starts, the
/// right answer is a route change, not a silent 1.5 GiB retransmission.
final class OneShotFileUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinning: PinningDelegate

    init(pinner: CertificatePinner) {
        pinning = PinningDelegate(pinner: pinner)
    }

    /// The redirect decision as a pure value, so the security-critical branch
    /// is unit-testable without synthesising a live task — the same shape
    /// ``PinningDelegate/serverTrustDisposition(pinnerEnabled:isPinnedHost:trustIsValid:)``
    /// already uses.
    ///
    /// Every status maps to `nil`. The parameter is kept so the refusal is
    /// stated per response rather than implied by an empty body.
    static func redirectRequest(for _: HTTPURLResponse) -> URLRequest? {
        nil
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        pinning.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectRequest(for: response))
    }
}

public extension APIClient {
    /// Overall ceiling for one file upload.
    ///
    /// The patient session's 60 s resource timeout is right for a JSON round
    /// trip and fatal for this route: a 1.5 GiB body cannot finish inside it on
    /// any connection a person actually has, so the upload was guaranteed to be
    /// cut off and — before this plan — retried whole. Six hours is generous
    /// enough that the ceiling never decides the outcome, while still bounding
    /// a task that has genuinely stalled. The *request* timeout stays short and
    /// is an inactivity timer, which `URLSession` resets as bytes move, so a
    /// progressing upload never trips it.
    static let fileUploadResourceTimeout: TimeInterval = 6 * 60 * 60
    static let fileUploadInactivityTimeout: TimeInterval = 60

    /// See ``APIClientProtocol/uploadFile(_:)``.
    func uploadFile<T: Decodable & Sendable>(_ request: APIFileUploadRequest<T>) async throws -> T {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await executeOneShotFileUpload(request)
            try ensureSuccess(response: response, data: data)
            return try decodePayload(T.self, data: data, status: response.statusCode)
        } catch {
            EndpointFailureDiagnostics.record(error, method: request.method, path: request.path, since: started)
            throw error
        }
    }

    /// The exact `URLRequest` a file upload puts on the wire, minus its body.
    ///
    /// Exposed so a test can read the headers deterministically rather than
    /// inferring them from whatever a mock transport happens to preserve — a
    /// `Content-Length` that `URLSession` recomputes downstream would make the
    /// "known length" contract unassertable at the only place it is decided.
    func fileUploadURLRequest<T: Decodable & Sendable>(for request: APIFileUploadRequest<T>) throws -> URLRequest {
        // Route, base URL, bearer, device id, CF-Access, idempotency key and the
        // account selector all come from the single existing builder. Only the
        // body's delivery is different here; nothing about the request's
        // identity is.
        var headers = request.extraHeaders
        headers["Content-Type"] = request.contentType
        var urlRequest = try buildURLRequest(APIRequest<T>(
            method: request.method,
            path: request.path,
            body: nil,
            extraHeaders: headers,
            idempotencyKey: request.idempotencyKey,
            maxRetries: 0,
            allowsAuthenticationRecovery: false
        ))
        // A known length up front. Chunked transfer of a body this size is a
        // worse bet on every proxy in the path, and a server that wants to
        // refuse an over-large upload can do so before the first byte of it.
        urlRequest.setValue(String(request.byteCount), forHTTPHeaderField: "Content-Length")
        return urlRequest
    }
}

extension APIClient {
    /// Build the dedicated one-shot session for a single upload.
    ///
    /// It inherits `protocolClasses` and the client's own additional headers
    /// from the patient session's configuration — the same inheritance the
    /// fail-fast and streaming sessions use — so a test's `URLProtocol` still
    /// intercepts and the User-Agent / X-Client-Type contract is unchanged.
    func makeOneShotUploadSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = session.configuration.protocolClasses
        config.httpAdditionalHeaders = session.configuration.httpAdditionalHeaders
        config.timeoutIntervalForRequest = Self.fileUploadInactivityTimeout
        config.timeoutIntervalForResource = Self.fileUploadResourceTimeout
        // A body this size must not sit parked waiting for an interface that is
        // not there; the user is looking at a progress indicator and can retry.
        config.waitsForConnectivity = false
        // No response of ours is cacheable and the request body is PHI.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: config,
            delegate: OneShotFileUploadDelegate(pinner: pinner),
            delegateQueue: nil
        )
    }

    /// One request. No retry loop, no refresh bridge, no redirect.
    ///
    /// The absence of `while true` here is the contract: ``execute(_:)``'s loop
    /// is what re-sends a body on a 5xx, a `URLError` or a refreshed bearer, and
    /// none of those may re-send this one.
    private func executeOneShotFileUpload(
        _ request: APIFileUploadRequest<some Decodable & Sendable>
    ) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try fileUploadURLRequest(for: request)
        // The authentication generation the body is being sent *under*. Read
        // before the request and compared after: a logout, an account switch or
        // a token refresh that lands mid-upload means the kickoff that comes
        // back belongs to a session the caller is no longer in, and publishing
        // it would attach one account's import job to another's screen.
        let authGeneration = keychain.getString(forKey: KeychainKey.authToken)

        let uploadSession = makeOneShotUploadSession()
        defer { uploadSession.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await uploadSession.upload(for: urlRequest, fromFile: request.bodyFileURL)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HLError.network(.other("non-HTTP response"))
        }
        // The client's centralized 401 policy, minus the recovery half. Every
        // route outside the ``preserves401Body`` allowlist collapses a 401 to
        // `.unauthorized`, and this route must answer the same way as the rest
        // of the client rather than inventing a second shape for the caller to
        // branch on. What it deliberately does *not* do is call the refresh
        // bridge and replay the body — that is the whole point of the route.
        // Consulting the same allowlist rather than hard-coding the collapse
        // means the two policies cannot drift if a future upload route needs
        // its 401 body.
        if http.statusCode == 401, !Self.preserves401Body(path: request.path) {
            throw HLError.unauthorized
        }
        guard keychain.getString(forKey: KeychainKey.authToken) == authGeneration else {
            throw HLError.unauthorized
        }
        return (data, http)
    }
}
