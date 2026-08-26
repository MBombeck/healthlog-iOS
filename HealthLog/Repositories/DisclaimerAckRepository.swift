import Foundation

/// Thin projection of the `GET /api/auth/me` payload — only the v1.18.6
/// (DISC-02) `disclaimerAcknowledgedAt` field. Decoupled from `UserProfile`
/// so an unrelated `/me` schema change can't break the read, mirroring
/// `AuthMeAvatar` / `AuthMeModules`.
///
/// **Decode-tolerant:** a server that omits the key (prod ≤ v1.18.5) yields
/// `nil` — treated downstream as "not yet acknowledged" so the one-time gate
/// still shows. `null` (acknowledged-never) decodes identically.
public struct AuthMeDisclaimer: Decodable, Sendable, Equatable {
    /// Server-stamped acknowledgment timestamp. `nil` when never acknowledged
    /// (or when the server omits the field).
    public let disclaimerAcknowledgedAt: Date?

    public init(disclaimerAcknowledgedAt: Date?) {
        self.disclaimerAcknowledgedAt = disclaimerAcknowledgedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disclaimerAcknowledgedAt = try container.decodeIfPresent(Date.self, forKey: .disclaimerAcknowledgedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case disclaimerAcknowledgedAt
    }
}

/// `POST /api/onboarding/disclaimer` body (OpenAPI `DisclaimerAckRequest`).
/// The `version` is a freshness signal only — the server pins and persists its
/// own canonical `DISCLAIMER_VERSION`. We echo the copy version the client
/// rendered so a stale shell cannot record an acknowledgment of copy it never
/// showed.
public struct DisclaimerAckBody: Encodable, Sendable, Equatable {
    public let version: String

    public init(version: String) {
        self.version = version
    }
}

/// `POST /api/onboarding/disclaimer` response (OpenAPI `DisclaimerAckResponse`).
/// The canonical version the server stamped.
public struct DisclaimerAckResponse: Decodable, Sendable, Equatable {
    public let acknowledgedVersion: String

    public init(acknowledgedVersion: String) {
        self.acknowledgedVersion = acknowledgedVersion
    }
}

/// Server-owned one-time medical-disclaimer acknowledgment (v1.18.6 / DISC-02).
/// Wraps the read + write:
///
/// - `GET  /api/auth/me`              — current `disclaimerAcknowledgedAt` (read).
/// - `POST /api/onboarding/disclaimer` — `{ version }` stamps the ack (write).
///
/// **Server-first:** the acknowledgment state is authoritative on the user row
/// (`User.disclaimerAcknowledgedAt`). iOS NEVER persists "acknowledged" to
/// UserDefaults/Keychain — the in-memory `DisclaimerAckStore` re-reads `/me`.
/// This replaces the per-page / per-chart disclaimer banners app-wide (the
/// server route's own contract note).
public actor DisclaimerAckRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Read the current acknowledgment timestamp from `GET /api/auth/me`.
    public func fetchAcknowledgedAt() async throws -> Date? {
        let req: APIRequest<AuthMeDisclaimer> = .get("/api/auth/me")
        return try await api.send(req).disclaimerAcknowledgedAt
    }

    /// Acknowledge the one-time medical disclaimer. Idempotent server-side.
    @discardableResult
    public func acknowledge(version: String) async throws -> DisclaimerAckResponse {
        let body = DisclaimerAckBody(version: version)
        let req: APIRequest<DisclaimerAckResponse> = try .post(
            "/api/onboarding/disclaimer",
            body: body
        )
        return try await api.send(req)
    }
}
