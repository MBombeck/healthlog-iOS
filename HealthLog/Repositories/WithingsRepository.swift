import Foundation

/// Wraps the Withings-integration verbs the Settings → Integrations surface
/// needs:
///
/// - `GET    /api/withings/status`     — connection + last-sync snapshot.
/// - `POST   /api/withings/sync`       — pull a measurement bucket now.
/// - `DELETE /api/withings/disconnect` — revoke the Withings link.
///
/// The connect flow is intentionally **not** here: it is browser-only by
/// design (3-leg OAuth, `05-auth-flows.md §4`) — the View opens
/// `/api/withings/connect` in the system browser directly, no API round-trip.
///
/// The paths live here, not in the View. The old screen hard-coded
/// `/api/withings/status` inline and a prior drift to `/api/integrations/...`
/// shipped a permanent "Not connected" 404 (W2a-A2 §8). The repo is the
/// contract-testable seam.
///
/// **Idempotency:** `sync` is a POST, so it carries an `Idempotency-Key`
/// header (`PROJECT_GUIDE.md`: "Idempotency-Keys auf jedem POST/PUT"); the
/// `idempotencyKey:` overload makes the key visible at the call site and lets a
/// future outbox replay reuse it (mirrors
/// `SourcePriorityRepository.update(_:idempotencyKey:)`). `disconnect` is a
/// DELETE — `HTTPMethod.requiresIdempotency` deliberately excludes DELETE
/// (idempotent on the path), so no wire-side key is needed. A dedicated outbox
/// `Kind` is intentionally not wired (user-initiated, low-rate Settings
/// actions, not the high-volume measurement/mood/med writes the Outbox is built
/// for); a failed mutation surfaces as an error, matching the prior in-View
/// behaviour exactly.
public actor WithingsRepository {
    /// `POST /api/withings/sync` body. `kind` selects the bucket; `measure`
    /// (vital-signs) is the iOS default for "pull everything Withings has".
    struct SyncBody: Encodable {
        let kind: String
    }

    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Reads the current connection status. Read-only, no cache — the screen
    /// re-fetches after every mutation to reflect server truth.
    public func status() async throws -> WithingsStatus {
        let req: APIRequest<WithingsStatus> = .get("/api/withings/status")
        return try await api.send(req)
    }

    /// Triggers a server-side pull of the given bucket. Default key per call.
    public func sync(kind: String = "measure") async throws {
        try await sync(kind: kind, idempotencyKey: IdempotencyKey())
    }

    /// Replay-friendly `sync` overload.
    public func sync(kind: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/withings/sync",
            body: SyncBody(kind: kind),
            idempotencyKey: idempotencyKey
        )
        try await api.sendVoid(req)
    }

    /// Revokes the Withings link. DELETE is idempotent on the path; no
    /// wire-side key is attached (see type doc).
    public func disconnect() async throws {
        let req: APIRequest<EmptyPayload> = .delete("/api/withings/disconnect")
        try await api.sendVoid(req)
    }
}
