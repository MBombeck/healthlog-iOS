import Foundation

/// Mirror of the `GET /api/<provider>/status` response shared by the
/// server-OAuth wearable integrations landed in server v1.17.0 — **Oura**,
/// **Polar** and **Fitbit** (Google Health). Each provider stores a token
/// server-side; `connected` is whether a token exists, `configured` whether the
/// provider is set up (env or per-user BYO credentials) so the connect flow can
/// run at all.
///
/// All non-essential fields are optional so additional server fields never
/// break iOS decoding — same tolerant shape as ``WithingsStatus``.
///
/// **The connection state is `health` only.** The ledger `state` and
/// `lastError` this struct used to decode are deprecated in server v1.43 and
/// removed in v1.44; nothing here reads them any more. A server before v1.42.4
/// sends no `health`, and the surface then shows no state line rather than a
/// guess.
public struct OAuthIntegrationStatus: Codable, Sendable, Hashable {
    public let connected: Bool
    public let configured: Bool?
    public let lastSyncedAt: Date?
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    public let connectedAt: Date?
    public let tokenExpiresAt: Date?
    public let scope: String?
    /// The server's unified connection state (v1.42.4+).
    public let health: ConnectionHealth?

    public init(
        connected: Bool,
        configured: Bool? = nil,
        lastSyncedAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        connectedAt: Date? = nil,
        tokenExpiresAt: Date? = nil,
        scope: String? = nil,
        health: ConnectionHealth? = nil
    ) {
        self.connected = connected
        self.configured = configured
        self.lastSyncedAt = lastSyncedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.connectedAt = connectedAt
        self.tokenExpiresAt = tokenExpiresAt
        self.scope = scope
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case connected, configured, lastSyncedAt, lastSuccessAt, lastAttemptAt
        case connectedAt, tokenExpiresAt, scope, health
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decode(Bool.self, forKey: .connected)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt)
        tokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        health = ConnectionHealth.tolerant(from: c, forKey: .health)
    }

    /// The most recent successful sync instant the surface can show — prefers
    /// the explicit `lastSyncedAt` (Fitbit) then the ledger `lastSuccessAt`
    /// (Oura / Polar).
    public var lastSync: Date? {
        lastSyncedAt ?? lastSuccessAt
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
///
/// Like ``OAuthIntegrationStatus`` it reads the connection state from
/// `health` only; the deprecated ledger `state` / `lastError` are gone.
public struct NightscoutStatus: Codable, Sendable, Hashable {
    public let connected: Bool
    public let configured: Bool?
    public let hasToken: Bool?
    public let allowPrivateHost: Bool?
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    /// The server's unified connection state (v1.42.4+).
    public let health: ConnectionHealth?

    public init(
        connected: Bool,
        configured: Bool? = nil,
        hasToken: Bool? = nil,
        allowPrivateHost: Bool? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        health: ConnectionHealth? = nil
    ) {
        self.connected = connected
        self.configured = configured
        self.hasToken = hasToken
        self.allowPrivateHost = allowPrivateHost
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case connected, configured, hasToken, allowPrivateHost, lastSuccessAt, lastAttemptAt, health
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decode(Bool.self, forKey: .connected)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured)
        hasToken = try c.decodeIfPresent(Bool.self, forKey: .hasToken)
        allowPrivateHost = try c.decodeIfPresent(Bool.self, forKey: .allowPrivateHost)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        health = ConnectionHealth.tolerant(from: c, forKey: .health)
    }
}
