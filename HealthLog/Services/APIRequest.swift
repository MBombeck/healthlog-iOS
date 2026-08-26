import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    public var requiresIdempotency: Bool {
        switch self {
        case .post, .put, .patch: true
        default: false
        }
    }
}

public struct APIRequest<Response: Sendable>: Sendable {
    public let method: HTTPMethod
    public let path: String
    public let query: [(String, String)]
    public let body: Data?
    public let extraHeaders: [String: String]
    public let idempotencyKey: IdempotencyKey
    public let maxRetries: Int
    /// #96 — route this request through `APIClient`'s FAIL-FAST auth session
    /// (`waitsForConnectivity = false`, short timeout) instead of the patient
    /// outbox session. Set only on interactive auth legs (passkey/login/
    /// register/refresh) so a no-connectivity attempt fails the login door
    /// immediately rather than parking on a dead spinner up to the 60 s
    /// resource timeout. Defaults `false` — every existing call keeps the
    /// patient session unchanged.
    public let failFast: Bool
    /// W-COACH-SSE — route this request through `APIClient`'s dedicated
    /// STREAMING session instead of the patient outbox session. The streaming
    /// session uses ``CoachStreamTimeoutPolicy`` values: a generous *inactivity*
    /// request timeout that URLSession resets on every chunk received (so a
    /// response that keeps producing SSE tokens never trips it) plus a generous
    /// overall resource ceiling (so a long-but-valid stream isn't capped by the
    /// 60 s wall the generic patient session imposes). Set only on the coach SSE
    /// turn (`POST /api/insights/chat`). Defaults `false` — every existing call
    /// keeps the patient session's 20 s/60 s policy unchanged. Mutually
    /// exclusive with `failFast` in practice (no auth leg streams); if both were
    /// somehow set, `failFast` wins (the auth session is selected first).
    public let streaming: Bool
    /// Account-leased requests carry an explicit Authorization header captured
    /// by their caller. A 401 must not invoke the process-global refresh/logout
    /// bridge because the authenticated account may have changed meanwhile.
    public let allowsAuthenticationRecovery: Bool

    public init(
        method: HTTPMethod,
        path: String,
        query: [(String, String)] = [],
        body: Data? = nil,
        extraHeaders: [String: String] = [:],
        idempotencyKey: IdempotencyKey = IdempotencyKey(),
        maxRetries: Int = 3,
        failFast: Bool = false,
        streaming: Bool = false,
        allowsAuthenticationRecovery: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.extraHeaders = extraHeaders
        self.idempotencyKey = idempotencyKey
        self.maxRetries = maxRetries
        self.failFast = failFast
        self.streaming = streaming
        self.allowsAuthenticationRecovery = allowsAuthenticationRecovery
    }
}

public extension APIRequest where Response: Decodable {
    static func get(_ path: String, query: [(String, String)] = []) -> APIRequest<Response> {
        APIRequest(method: .get, path: path, query: query)
    }
}

public extension APIRequest {
    static func post(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = .hlDefault,
        idempotencyKey: IdempotencyKey = IdempotencyKey(),
        maxRetries: Int = 3,
        failFast: Bool = false
    ) throws -> APIRequest<Response> {
        let data = try encoder.encode(body)
        return APIRequest(
            method: .post,
            path: path,
            body: data,
            idempotencyKey: idempotencyKey,
            maxRetries: maxRetries,
            failFast: failFast
        )
    }

    static func patch(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = .hlDefault,
        idempotencyKey: IdempotencyKey = IdempotencyKey(),
        maxRetries: Int = 3
    ) throws -> APIRequest<Response> {
        let data = try encoder.encode(body)
        return APIRequest(method: .patch, path: path, body: data, idempotencyKey: idempotencyKey, maxRetries: maxRetries)
    }

    static func put(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = .hlDefault,
        idempotencyKey: IdempotencyKey = IdempotencyKey(),
        maxRetries: Int = 3
    ) throws -> APIRequest<Response> {
        let data = try encoder.encode(body)
        return APIRequest(method: .put, path: path, body: data, idempotencyKey: idempotencyKey, maxRetries: maxRetries)
    }

    static func delete(_ path: String, idempotencyKey: IdempotencyKey = IdempotencyKey()) -> APIRequest<Response> {
        APIRequest(method: .delete, path: path, idempotencyKey: idempotencyKey)
    }

    /// DELETE with body (used by `/api/measurements/by-external-ids` bulk
    /// route — server expects a JSON array of externalIds, which a query
    /// param would not fit cleanly). HTTP/1.1 + most proxies tolerate this.
    static func delete(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = .hlDefault,
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) throws -> APIRequest<Response> {
        let data = try encoder.encode(body)
        return APIRequest(method: .delete, path: path, body: data, idempotencyKey: idempotencyKey)
    }
}

/// Decodable placeholder for endpoints that respond with 2xx + empty body or
/// `{}`. Decoder treats both shapes as `EmptyResponse()`.
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
    public init(from _: Decoder) throws {
        self.init()
    }
}

public extension JSONEncoder {
    /// Default Encoder für alle Repos. Server (Next.js + Prisma) erwartet
    /// camelCase, keine snake_case-Konversion.
    static let hlDefault: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
