import Foundation

/// Wraps the server-OAuth wearable verbs shared by **Oura**, **Polar** and
/// **Fitbit** (server v1.17.0 — `MeasurementSource` providers whose data
/// already flows server-side; this surfaces the missing iOS manage card).
///
/// The contract mirrors Withings with **one delta**: `disconnect` is a `POST`
/// (the server exposes `export const POST` on `/api/<provider>/disconnect`),
/// not the Withings `DELETE`. Verbs:
///
/// - `GET  /api/<provider>/status`     — connection + ledger snapshot.
/// - `POST /api/<provider>/disconnect` — revoke the link.
/// - `POST /api/<provider>/sync`       — (Fitbit only) pull now.
///
/// The connect flow is intentionally **not** here: like Withings it is
/// browser-only by design (server-brokered 3-leg OAuth — `GET
/// /api/<provider>/connect` is a 302 redirect to the provider's consent
/// screen). The View opens it in the system browser; no API round-trip, so no
/// repo seam. The single shared base path (`provider`) is the contract-testable
/// seam, replacing the per-screen hard-coded path that bit Withings (W2a-A2).
public actor OAuthIntegrationRepository {
    /// The server-OAuth providers this repo brokers. The raw value is the
    /// `/api/<provider>/…` path segment.
    public enum Provider: String, Sendable, CaseIterable {
        case oura
        case polar
        case fitbit
        /// v1.28.11 (#46) — Strava workout/activity ingest. Same server-OAuth
        /// shape as Oura/Polar (browser connect, status, disconnect) plus per-user
        /// BYO credentials + a live token-probe `/test`.
        case strava

        /// Whether this provider exposes a manual `/sync` route.
        ///
        /// **CU-35 (1) — all four do now.** Fitbit had `POST /api/fitbit/sync`
        /// from the start; server v1.32.28 added the same route to Oura, Polar
        /// and Strava (`src/app/api/{oura,polar,strava}/sync/route.ts`), each
        /// answering the identical ``ManualSyncResult`` envelope. Until now iOS
        /// showed the button on Fitbit only, so a user who could see Oura was
        /// behind had no way to ask for a fresh pull.
        var supportsManualSync: Bool {
            switch self {
            case .oura, .polar, .fitbit, .strava: true
            }
        }

        /// Whether this provider exposes a `POST /api/<provider>/test` live
        /// token-probe. Oura / Polar / Strava do; Fitbit's probe lives under a
        /// different path (`/api/integrations/fitbit/test`) so it is not wired
        /// through this shared repo.
        var supportsConnectionTest: Bool {
            switch self {
            case .oura, .polar, .strava: true
            case .fitbit: false
            }
        }
    }

    private let api: APIClientProtocol
    private let provider: Provider

    public init(api: APIClientProtocol, provider: Provider) {
        self.api = api
        self.provider = provider
    }

    private var base: String {
        "/api/\(provider.rawValue)"
    }

    /// Reads the current connection status. Read-only, no cache — the screen
    /// re-fetches after every mutation to reflect server truth.
    public func status() async throws -> OAuthIntegrationStatus {
        let req: APIRequest<OAuthIntegrationStatus> = .get("\(base)/status")
        return try await api.send(req)
    }

    /// Revokes the link. `POST` (server contract) with an empty body.
    public func disconnect() async throws {
        let req: APIRequest<EmptyPayload> = try .post("\(base)/disconnect", body: EmptyBody())
        try await api.sendVoid(req)
    }

    /// Triggers a server-side pull now (`POST /api/<provider>/sync`).
    ///
    /// **CU-35 (1) — the answer is read, not discarded.** This used to be a
    /// `sendVoid`, so `{ imported, failed, outcome }` was thrown away and the
    /// screen could only say "done". It now returns the server's own verdict so
    /// the surface can tell "nothing new over there" apart from "nothing landed".
    ///
    /// **`maxRetries: 0` is load-bearing, twice over.** The route is rate-limited
    /// 5 per 60 s per user, and `APIClient` treats both a 429 and a 5xx as
    /// retriable — so the default budget of 3 would spend four of the five
    /// permitted calls on one tap and turn a single 502 into four fan-outs at the
    /// provider. It also means the 429 and the 502 reach the caller as themselves
    /// instead of after a backoff, which is what makes the three states
    /// distinguishable at all. Same reasoning `AuthService` applies to the
    /// aggressively rate-limited auth legs.
    public func sync() async throws -> ManualSyncResult {
        let req: APIRequest<ManualSyncResult> = try .post(
            "\(base)/sync",
            body: EmptyBody(),
            idempotencyKey: IdempotencyKey(),
            maxRetries: 0
        )
        return try await api.send(req)
    }

    // MARK: - BYO credentials (per-user OAuth client id/secret)

    /// `GET /api/<provider>/credentials` → `{ hasCredentials }`. Whether the user
    /// has stored their own OAuth client id/secret pair; when absent the server
    /// falls back to its shared env app (managed cloud) so the connect flow still
    /// works. On a self-hosted instance without an env app, BYO credentials are
    /// the ONLY way to connect.
    public func credentialsStatus() async throws -> BYOCredentialsStatus {
        let req: APIRequest<BYOCredentialsStatus> = .get("\(base)/credentials")
        return try await api.send(req)
    }

    /// `PUT /api/<provider>/credentials` — store the user's OAuth client id +
    /// secret (encrypted at rest server-side). The secret never returns on any
    /// read; iOS holds it only transiently in the form field.
    public func saveCredentials(clientId: String, clientSecret: String) async throws {
        let req: APIRequest<EmptyPayload> = try .put(
            "\(base)/credentials",
            body: BYOCredentialsBody(clientId: clientId, clientSecret: clientSecret)
        )
        try await api.sendVoid(req)
    }

    /// `DELETE /api/<provider>/credentials` — forget the stored client id/secret.
    /// Server-side this also drops any live connection minted against them (an
    /// orphaned token), parking the integration ledger at `disconnected`.
    public func deleteCredentials() async throws {
        let req: APIRequest<EmptyPayload> = .delete("\(base)/credentials")
        try await api.sendVoid(req)
    }

    /// `POST /api/<provider>/test` — a live token probe (Oura / Polar / Strava).
    /// Confirms the stored grant is still valid by hitting the cheapest
    /// authenticated provider call. Returns latency on success; a rejected token
    /// / timeout surfaces as a typed `HLError`.
    public func test() async throws -> ConnectionTestResult {
        let req: APIRequest<ConnectionTestResult> = try .post("\(base)/test", body: EmptyBody())
        return try await api.send(req)
    }

    private struct EmptyBody: Encodable {}
}
