import Foundation

/// Wraps the WHOOP-integration verbs the Settings → Integrations surface needs.
///
/// WHOOP mirrors the Withings server-brokered OAuth flow (`/api/whoop/connect`
/// 302's into WHOOP's authorize page; the callback exchanges the code + persists
/// an encrypted connection), with **one delta**: WHOOP is BYO-key. Each user
/// pastes their own WHOOP developer **Client ID + Client Secret** first
/// (`PUT /api/whoop/credentials`); `GET /api/whoop/connect` returns **400**
/// until they are saved, and `status.configured` stays `false`. The Settings
/// gate therefore drives off `status.configured` (creds present) AND
/// `status.connected` (OAuth done).
///
/// - `GET    /api/whoop/status`           — connection + last-sync snapshot.
/// - `GET    /api/whoop/credentials`      — `{ hasCredentials }`.
/// - `PUT    /api/whoop/credentials`      — save `{ clientId, clientSecret }`.
/// - `DELETE /api/whoop/credentials`      — wipe creds + connection.
/// - `POST   /api/whoop/sync`             — pull now (optional `{ fullSync }`).
/// - `POST   /api/whoop/disconnect`       — revoke the WHOOP link.
/// - `POST   /api/integrations/whoop/test`   — probe (`{ ok, lastSyncedAt, latencyMs }`).
/// - `POST   /api/integrations/whoop/resume` — un-park a rate-parked connection.
///
/// The connect flow is intentionally **not** here: it is browser-only by design
/// (server-brokered 3-leg OAuth) — the View opens `/api/whoop/connect` in the
/// system browser directly, no API round-trip (mirrors `WithingsRepository`).
///
/// **clientSecret handling:** the secret is sent **once** via `PUT` and the
/// server stores it encrypted. It is never persisted client-side and never
/// logged — `SaveCredentialsBody` is not `CustomStringConvertible`, and no
/// logging path touches it. The status/credentials reads never return it.
///
/// **Idempotency:** `sync` is a POST carrying an `Idempotency-Key`; the
/// `idempotencyKey:` overload makes the key visible at the call site (mirrors
/// `WithingsRepository.sync`). The credentials `PUT` is a single user-initiated
/// upsert and rides the default key. `disconnect` / `test` / `resume` are POSTs
/// with default keys; `DELETE` is idempotent on the path. No dedicated outbox
/// `Kind` is wired — these are user-initiated, low-rate Settings actions, not
/// the high-volume measurement/mood/med writes the Outbox is built for.
public actor WhoopRepository {
    /// `PUT /api/whoop/credentials` body. The `clientSecret` is sent once and
    /// is never persisted or logged client-side (see type doc).
    struct SaveCredentialsBody: Encodable {
        let clientId: String
        let clientSecret: String
    }

    /// `POST /api/whoop/sync` body. `fullSync` requests a backfill pull.
    struct SyncBody: Encodable {
        let fullSync: Bool
    }

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Reads the current connection + credential-configured status. Read-only,
    /// no cache — the screen re-fetches after every mutation.
    public func status() async throws -> WhoopStatus {
        let req: APIRequest<WhoopStatus> = .get("/api/whoop/status")
        return try await api.send(req)
    }

    /// Saves the per-user WHOOP Client ID + Secret. The secret leaves the
    /// device exactly once, here; the server stores it encrypted.
    public func saveCredentials(clientId: String, clientSecret: String) async throws {
        let req: APIRequest<EmptyPayload> = try .put(
            "/api/whoop/credentials",
            body: SaveCredentialsBody(clientId: clientId, clientSecret: clientSecret)
        )
        try await api.sendVoid(req)
    }

    /// Wipes the stored credentials AND the OAuth connection (destructive).
    public func deleteCredentials() async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/whoop/credentials")
        try await api.sendVoid(req)
    }

    /// Triggers a server-side pull. Default key per call.
    public func sync(fullSync: Bool = false) async throws {
        try await sync(fullSync: fullSync, idempotencyKey: IdempotencyKey())
    }

    /// Replay-friendly `sync` overload.
    public func sync(fullSync: Bool, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/whoop/sync",
            body: SyncBody(fullSync: fullSync),
            idempotencyKey: idempotencyKey
        )
        try await api.sendVoid(req)
    }

    /// Revokes the WHOOP OAuth link (keeps stored credentials).
    public func disconnect() async throws {
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/whoop/disconnect",
            body: EmptyBody()
        )
        try await api.sendVoid(req)
    }

    /// Probes the live WHOOP connection. Returns `{ ok, lastSyncedAt, latencyMs }`
    /// on success; throws an `HLError.server` carrying the mapped `errorCode`
    /// otherwise (`not_configured`, `credentials_rejected`, `rate_limited`,
    /// `upstream_error`, `connection_failed`, `timeout`, `rate_limited_self`).
    public func test() async throws -> WhoopTestResult {
        let req: APIRequest<WhoopTestResult> = try .post(
            "/api/integrations/whoop/test",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    /// Un-parks a rate-limit-parked connection.
    public func resume() async throws -> WhoopResumeResult {
        let req: APIRequest<WhoopResumeResult> = try .post(
            "/api/integrations/whoop/resume",
            body: EmptyBody()
        )
        return try await api.send(req)
    }
}

/// Empty JSON `{}` POST body for the bodiless WHOOP POSTs.
private struct EmptyBody: Encodable {}

/// Mirror of `GET /api/whoop/status`. `connected` + `configured` drive the
/// Settings state machine (BYO-key gate); the rest is decoded tolerantly (all
/// optional) so extra server fields never break iOS.
public struct WhoopStatus: Codable, Sendable {
    public let connected: Bool
    /// `true` once per-user Client ID/Secret are saved. Gate the Connect CTA
    /// on this — `false` ⇒ show the credentials-entry step.
    public let configured: Bool?
    public let lastSyncedAt: Date?
    public let connectedAt: Date?
    /// **Legacy, fallback only.** Deprecated in server v1.43, removed in
    /// v1.44. Read only when ``health`` is absent (a server before v1.42.4);
    /// every other reader goes through ``health``.
    public let tokenExpired: Bool?
    public let tokenExpiresAt: Date?
    public let backfillCompleted: Bool?
    public let scope: String?
    /// The server's unified connection state (v1.42.4+).
    public let health: ConnectionHealth?

    public init(
        connected: Bool,
        configured: Bool?,
        lastSyncedAt: Date?,
        connectedAt: Date?,
        tokenExpired: Bool?,
        tokenExpiresAt: Date?,
        backfillCompleted: Bool?,
        scope: String?,
        health: ConnectionHealth? = nil
    ) {
        self.connected = connected
        self.configured = configured
        self.lastSyncedAt = lastSyncedAt
        self.connectedAt = connectedAt
        self.tokenExpired = tokenExpired
        self.tokenExpiresAt = tokenExpiresAt
        self.backfillCompleted = backfillCompleted
        self.scope = scope
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case connected, configured, lastSyncedAt, connectedAt, tokenExpired
        case tokenExpiresAt, backfillCompleted, scope, health
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decode(Bool.self, forKey: .connected)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt)
        // Fallback field: once v1.44 drops it, absence is the normal case.
        tokenExpired = try? c.decodeIfPresent(Bool.self, forKey: .tokenExpired)
        tokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        backfillCompleted = try c.decodeIfPresent(Bool.self, forKey: .backfillCompleted)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        health = ConnectionHealth.tolerant(from: c, forKey: .health)
    }

    /// The connection is broken until the person reconnects. From
    /// ``health`` when the server sends it; the legacy `tokenExpired` only
    /// answers for a server that does not.
    public var needsReconnect: Bool {
        if let health { return health.needsReconnect }
        return tokenExpired == true
    }
}

/// Mirror of the `POST /api/integrations/whoop/test` success branch.
public struct WhoopTestResult: Codable, Sendable {
    public let ok: Bool
    public let lastSyncedAt: Date?
    public let latencyMs: Int?
}

/// Mirror of `POST /api/integrations/whoop/resume`.
public struct WhoopResumeResult: Codable, Sendable {
    public let resumed: Bool
    public let wasParked: Bool?
}
