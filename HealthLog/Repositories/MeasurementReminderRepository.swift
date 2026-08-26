import Foundation

/// **W-REMINDERS (#23 v1.18.1) — Vorsorge measurement-reminder CRUD.**
///
/// Thin wire wrapper over the server `MeasurementReminders` routes (live since
/// server v1.17.1, `origin`/`endsOn` added v1.18.1):
///
/// - `GET    /api/measurement-reminders`            → list (sorted nextDueAt asc)
/// - `POST   /api/measurement-reminders`            → create
/// - `PATCH  /api/measurement-reminders/{id}`       → edit (partial)
/// - `DELETE /api/measurement-reminders/{id}`       → soft-delete (idempotent)
/// - `POST   /api/measurement-reminders/{id}/satisfy` → MANUAL "Erledigt"
///
/// Plus the accepted v1.37.20 surface (server tag `3a2c0e75`, frozen by Plan
/// 08-18 under `HealthLogTests/Fixtures/Server/v1.37.20/`):
///
/// - `POST   /api/measurement-reminders/{id}/skip`    → honest skip of a cycle
/// - `POST   /api/measurement-reminders/{id}/snooze`  → push the due day back
/// - `GET    /api/measurement-reminders/{id}/history` → completion ledger page
///
/// The `APIClient` auto-unwraps the `{ data, error, meta }` envelope (see
/// `APIEnvelope` + `APIClient.decodePayload`), so each call decodes straight to
/// the payload type.
///
/// **No Outbox enqueue (deliberate, MVP scope).** These mutations are all
/// interactive actions on the manage-reminders screen (create / edit / mark
/// done / delete), not silent background writes — they surface their error to
/// the user inline, who retries. The full Outbox path would require new
/// `OutboxQueue.Operation.Kind` cases + `Payloads` + an `OutboxReplayService`
/// dispatch arm, a cross-cutting change out of scope for the reminder MVP. Each
/// write still carries a fresh idempotency key (the `APIRequest.post/patch`
/// default), so a manual retry after a network blip is double-write safe.
///
/// **Auto-satisfy is server-side.** A matching `Measurement`/`LabResult`/
/// wearable-sync advances `nextDueAt` + stamps `lastSatisfiedAt` server-side, so
/// the client NEVER calls `satisfy` on a measurement write — `satisfy(id:)` is
/// only the user's explicit "mark done" tap.
public actor MeasurementReminderRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    private static let basePath = "/api/measurement-reminders"

    /// `GET /api/measurement-reminders` — the owner's live reminders, server-
    /// sorted by `nextDueAt` ascending (nulls last). Render the order as given.
    public func list() async throws -> [MeasurementReminderRow] {
        let req: APIRequest<[MeasurementReminderRow]> = .get(Self.basePath)
        return try await api.send(req)
    }

    /// `POST /api/measurement-reminders` — create a Vorsorge reminder. Server
    /// computes the authoritative `nextDueAt`. Returns the created row.
    public func create(_ body: MeasurementReminderCreate) async throws -> MeasurementReminderRow {
        let req: APIRequest<MeasurementReminderRow> = try .post(Self.basePath, body: body)
        return try await api.send(req)
    }

    /// `PATCH /api/measurement-reminders/{id}` — partial edit. Server recomputes
    /// `nextDueAt` after the cadence merge. Returns the updated row.
    public func update(id: String, patch: MeasurementReminderUpdate) async throws -> MeasurementReminderRow {
        let req: APIRequest<MeasurementReminderRow> = try .patch("\(Self.basePath)/\(id)", body: patch)
        return try await api.send(req)
    }

    /// `DELETE /api/measurement-reminders/{id}` — soft-delete (tombstone).
    /// Idempotent server-side. The success envelope is `{ data: { deleted } }`;
    /// we don't act on the flag (the store removes the row optimistically), so we
    /// decode the canonical `EmptyResponse` — its body-ignoring decoder tolerates
    /// any 2xx data shape, matching the codebase's standard "fire + forget DELETE"
    /// pattern (see `ConsentReceiptRepository.revokeAll`).
    public func delete(id: String) async throws {
        let req: APIRequest<EmptyResponse> = .delete("\(Self.basePath)/\(id)")
        _ = try await api.send(req)
    }

    /// `POST /api/measurement-reminders/{id}/satisfy` — the MANUAL "Erledigt"
    /// action. Stamps `lastSatisfiedAt = now` and re-anchors `nextDueAt` past
    /// now, server-side. Returns the re-anchored row. **Never** call this on a
    /// measurement write — typed reminders auto-resolve in the server cron.
    public func satisfy(id: String) async throws -> MeasurementReminderRow {
        // Empty JSON body — the server route takes no payload, but a POST still
        // carries the idempotency key (APIRequest.post default).
        let req: APIRequest<MeasurementReminderRow> = try .post(
            "\(Self.basePath)/\(id)/satisfy",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    /// `POST /api/measurement-reminders/{id}/complete` (v1.18.6, #32) — the
    /// EXPLICIT user-action completion, the twin of `satisfy`. Marks the
    /// reminder done server-side (stamps `lastSatisfiedAt = now`, re-anchors
    /// `nextDueAt`, fires NO notification) so the "Erledigt" tap is
    /// server-authoritative instead of a local-only deep-link dismiss.
    ///
    /// **Idempotent + owner-scoped.** Completing an already-satisfied /
    /// auto-resolved reminder returns `200` with `completed = false` (no-op);
    /// a foreign / missing id is a `404`. Returns the
    /// `MeasurementReminderCompletion` envelope (`{ completed, reminder }`).
    public func complete(id: String) async throws -> MeasurementReminderCompletion {
        let req: APIRequest<MeasurementReminderCompletion> = try .post(
            "\(Self.basePath)/\(id)/complete",
            body: EmptyBody()
        )
        return try await api.send(req)
    }

    /// `POST /api/measurement-reminders/{id}/skip` (v1.37.20) — honestly skip
    /// the current due cycle. The interval restarts from the skip instant,
    /// `lastSkippedAt` is stamped, `skipCount` increments, any snooze is
    /// cleared, and a `SKIPPED` row lands in the completion ledger.
    /// `lastSatisfiedAt` is never touched: a skip is not a completion.
    ///
    /// **The route declares no request body at all**, which is where it differs
    /// from `satisfy` and `complete` (both POST `{}` via `EmptyBody`). So the
    /// request is built directly rather than through `APIRequest.post`: no body
    /// and therefore no `Content-Type`, while the POST still carries a fresh
    /// `Idempotency-Key` from the default key — sending `{}` anyway would assert
    /// a payload the published contract does not have.
    ///
    /// Returns the `{ skipped, reminder }` envelope; `skipped == false` is the
    /// idempotent no-op, not an error. Errors are the published set: `401`,
    /// `403`, `404` (foreign, missing, or appointment reminder), `422`, `429`.
    public func skip(id: String) async throws -> MeasurementReminderSkip {
        let req = APIRequest<MeasurementReminderSkip>(
            method: .post,
            path: "\(Self.basePath)/\(id)/skip"
        )
        return try await api.send(req)
    }

    /// `POST /api/measurement-reminders/{id}/snooze` (v1.37.20) — push the
    /// current due date back to a named calendar day (`YYYY-MM-DD`; build it
    /// with ``MeasurementReminderSnooze/day(_:in:)``). The server resolves the
    /// day to the reminder's `notifyHour` in the profile timezone and sets
    /// `snoozedUntil` and `nextDueAt` to that same instant; the regular cadence,
    /// `lastSatisfiedAt`, `lastSkippedAt` and the anchor all stay put.
    ///
    /// The body is `required` here — the asymmetry with `skip` is the contract,
    /// not an oversight. The response is the inline `{ reminder }` object, with
    /// no applied flag (repeated snoozes: last one wins), so the caller receives
    /// the canonical row. Errors: `401`, `403`, `404`, `422` (a day earlier than
    /// tomorrow or more than five years out), `429`.
    public func snooze(id: String, until day: String) async throws -> MeasurementReminderRow {
        let req: APIRequest<MeasurementReminderSnoozeResult> = try .post(
            "\(Self.basePath)/\(id)/snooze",
            body: MeasurementReminderSnooze(until: day)
        )
        return try await api.send(req).reminder
    }

    /// `GET /api/measurement-reminders/{id}/history` (v1.37.20) — one page of the
    /// reminder's completion ledger, newest first: a row per satisfy (from any
    /// path) and per skip, with a server-derived `onTime`.
    ///
    /// `limit` (1…100, server default 50) and `offset` (≥ 0, default 0) are sent
    /// only when the caller passes them, so omitting them gets the published
    /// defaults verbatim instead of a client-side guess at what they are. A value
    /// outside the bounds is the server's `422`; nothing is clamped here, because
    /// silently rewriting the page window would hide the refusal.
    ///
    /// An empty page is an honest answer, not a failure: the ledger begins at the
    /// release that introduced it and cannot be backfilled.
    public func history(
        id: String,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> MeasurementReminderHistoryPage {
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        if let offset { query.append(("offset", String(offset))) }
        let req: APIRequest<MeasurementReminderHistoryPage> = .get("\(Self.basePath)/\(id)/history", query: query)
        return try await api.send(req)
    }

    /// Encodes to `{}` for routes that POST without a body.
    private struct EmptyBody: Encodable {}
}
