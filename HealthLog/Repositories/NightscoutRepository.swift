import Foundation

/// Wraps the **Nightscout** self-hoster integration verbs (server v1.17.0).
/// Unlike the OAuth wearables, Nightscout is a URL-+-token paste flow — the
/// user points HealthLog at their own Nightscout instance, so the connect step
/// is a plain `POST` with a JSON body (no browser redirect, no OAuth):
///
/// - `GET  /api/nightscout/status`     — connection + ledger snapshot.
/// - `POST /api/nightscout/connect`    — `{ url, token?, allowPrivateHost? }`.
/// - `POST /api/nightscout/disconnect` — forget the stored instance.
///
/// The URL + token are stored encrypted server-side; iOS never persists them.
/// The token is opaque (a role-scoped access token or the raw `API_SECRET`) and
/// optional — a fully public instance serves SGV entries without one.
public actor NightscoutRepository {
    /// `POST /api/nightscout/connect` body — mirrors `nightscoutConnectSchema`.
    /// `Codable` (not just `Encodable`) so tests can round-trip the wire body.
    public struct ConnectBody: Codable, Sendable {
        public let url: String
        public let token: String
        public let allowPrivateHost: Bool

        public init(url: String, token: String, allowPrivateHost: Bool) {
            self.url = url
            self.token = token
            self.allowPrivateHost = allowPrivateHost
        }
    }

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func status() async throws -> NightscoutStatus {
        let req: APIRequest<NightscoutStatus> = .get("/api/nightscout/status")
        return try await api.send(req)
    }

    /// Saves the instance URL (+ optional token). The server validates the URL
    /// shape and returns 422 on garbage; the error surfaces to the screen.
    public func connect(url: String, token: String, allowPrivateHost: Bool) async throws {
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/nightscout/connect",
            body: ConnectBody(url: url, token: token, allowPrivateHost: allowPrivateHost),
            idempotencyKey: IdempotencyKey()
        )
        try await api.sendVoid(req)
    }

    /// Forgets the stored instance. `POST` (server contract) with empty body.
    public func disconnect() async throws {
        let req: APIRequest<EmptyPayload> = try .post("/api/nightscout/disconnect", body: EmptyBody())
        try await api.sendVoid(req)
    }

    /// **CU-35 (1)** — `POST /api/nightscout/sync` (server v1.32.28): pull the
    /// recent SGV window from the configured instance now, instead of waiting
    /// for the cron tick. No body, no query.
    ///
    /// `imported` counts the readings that were genuinely new this run, not the
    /// ones re-confirmed — so a window in which every row was refused by a
    /// constraint imports `0` and `outcome` says `failed`, which must not read
    /// like a quiet night.
    ///
    /// `maxRetries: 0` for the same two reasons as the OAuth sibling: the route
    /// is capped at 5 per 60 s, and every run is an outbound call to a
    /// user-supplied host — a retry loop would hammer both.
    public func sync() async throws -> ManualSyncResult {
        let req: APIRequest<ManualSyncResult> = try .post(
            "/api/nightscout/sync",
            body: EmptyBody(),
            idempotencyKey: IdempotencyKey(),
            maxRetries: 0
        )
        return try await api.send(req)
    }

    /// `POST /api/nightscout/test` — a live probe that re-validates the stored
    /// URL + token by pulling a single SGV entry. Returns `{ ok, latencyMs }`; a
    /// rejected token / unreachable instance surfaces as a typed `HLError`.
    public func test() async throws -> ConnectionTestResult {
        let req: APIRequest<ConnectionTestResult> = try .post("/api/nightscout/test", body: EmptyBody())
        return try await api.send(req)
    }

    private struct EmptyBody: Encodable {}
}
