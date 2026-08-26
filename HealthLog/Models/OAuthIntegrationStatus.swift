import Foundation

/// Mirror of the `GET /api/<provider>/status` response shared by the
/// server-OAuth wearable integrations landed in server v1.17.0 — **Oura**,
/// **Polar** and **Fitbit** (Google Health). Each provider stores a token
/// server-side; `connected` is whether a token exists, `configured` whether the
/// provider is set up (env or per-user BYO credentials) so the connect flow can
/// run at all.
///
/// All non-essential fields are optional so additional server fields never
/// break iOS decoding — same tolerant shape as ``WithingsStatus``. The
/// integration-ledger `state` ("ok" / "parked" / "error") + the
/// last-success/attempt timestamps surface the same honest pill the web cards
/// render.
public struct OAuthIntegrationStatus: Codable, Sendable, Hashable {
    public let connected: Bool
    public let configured: Bool?
    /// Integration-ledger health: `ok` / `parked` / `error` (provider-defined).
    public let state: String?
    public let lastSyncedAt: Date?
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    public let lastError: String?
    public let connectedAt: Date?
    public let tokenExpiresAt: Date?
    public let scope: String?

    public init(
        connected: Bool,
        configured: Bool? = nil,
        state: String? = nil,
        lastSyncedAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        connectedAt: Date? = nil,
        tokenExpiresAt: Date? = nil,
        scope: String? = nil
    ) {
        self.connected = connected
        self.configured = configured
        self.state = state
        self.lastSyncedAt = lastSyncedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.connectedAt = connectedAt
        self.tokenExpiresAt = tokenExpiresAt
        self.scope = scope
    }

    /// The most recent successful sync instant the surface can show — prefers
    /// the explicit `lastSyncedAt` (Fitbit) then the ledger `lastSuccessAt`
    /// (Oura / Polar).
    public var lastSync: Date? {
        lastSyncedAt ?? lastSuccessAt
    }

    /// `true` when the integration ledger reports a non-healthy state — the UI
    /// surfaces a calm "needs attention" pill rather than a flat "Connected".
    public var isParkedOrError: Bool {
        guard let state else { return false }
        return state != "ok"
    }
}

/// Mirror of `GET /api/<provider>/credentials` → `{ hasCredentials }` — whether
/// the user has stored their own OAuth client id/secret (BYO). When `false` the
/// server falls back to its shared env app (managed cloud); on a self-hosted
/// instance without an env app, BYO credentials are the only way to connect.
public struct BYOCredentialsStatus: Codable, Sendable, Hashable {
    public let hasCredentials: Bool

    public init(hasCredentials: Bool) {
        self.hasCredentials = hasCredentials
    }

    private enum CodingKeys: String, CodingKey {
        case hasCredentials
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredentials = try c.decodeIfPresent(Bool.self, forKey: .hasCredentials) ?? false
    }
}

/// `PUT /api/<provider>/credentials` body — the user's OAuth client id + secret.
/// `Codable` (not just `Encodable`) so tests can round-trip the wire body. Maps
/// 1:1 onto the server `*CredentialsSchema` (`{ clientId, clientSecret }`).
public struct BYOCredentialsBody: Codable, Sendable {
    public let clientId: String
    public let clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// Mirror of the live connection-probe response shared by the OAuth providers'
/// `POST /api/<provider>/test` and `POST /api/nightscout/test`:
/// `{ ok, latencyMs }`. `latencyMs` is tolerant (absent → `nil`).
public struct ConnectionTestResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let latencyMs: Int?

    public init(ok: Bool, latencyMs: Int? = nil) {
        self.ok = ok
        self.latencyMs = latencyMs
    }

    private enum CodingKeys: String, CodingKey {
        case ok, latencyMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs)
    }
}

/// Mirror of `GET /api/nightscout/status`. Nightscout is **not** OAuth — the
/// self-hoster pastes their instance URL (+ optional API token) which the
/// server stores encrypted; `configured` is whether a URL is stored.
public struct NightscoutStatus: Codable, Sendable, Hashable {
    public let connected: Bool
    public let configured: Bool?
    public let hasToken: Bool?
    public let allowPrivateHost: Bool?
    public let state: String?
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    public let lastError: String?

    public init(
        connected: Bool,
        configured: Bool? = nil,
        hasToken: Bool? = nil,
        allowPrivateHost: Bool? = nil,
        state: String? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.connected = connected
        self.configured = configured
        self.hasToken = hasToken
        self.allowPrivateHost = allowPrivateHost
        self.state = state
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    public var isParkedOrError: Bool {
        guard let state else { return false }
        return state != "ok"
    }
}
