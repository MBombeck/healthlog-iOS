import Foundation

/// Actor repository for the v1.25 opt-in mental-health screener surface
/// (`/api/mental-health/assessments`). PHQ-9 / GAD-7. Mirrors
/// ``AllergiesRepository``: SWR cache-first history read when a coordinator is
/// supplied (QOL-OFF-2 — the DERIVED history is offline-readable; the raw item
/// answers are NEVER returned by the endpoint so nothing sensitive beyond the
/// score/band is cached), an optimistic outbox-backed POST through `APIClient`.
/// Append-only: a successful submit invalidates `.mentalHealthHistory`; logout
/// purges every row via `SWRCoordinator.invalidateAll()`.
///
/// **SAFETY.** The per-item answers are PHI: encrypted at rest server-side, never
/// returned by any endpoint, never persisted client-side beyond the in-flight
/// outbox payload, never logged. The server computes the authoritative total /
/// band / item-9 flag and (on a positive item-9) returns the locale-aware crisis
/// set. The crisis card is driven by that response when online; the store falls
/// back to ``CrisisResourceFallback`` when the POST fails or omits `crisis`, so a
/// positive item-9 is NEVER unsignposted.
///
/// **Outbox durability (PHI write).** On a retriable failure
/// (`HLError.shouldPersistToOutbox`) the create is persisted to the encrypted
/// `OutboxQueue` under its idempotency key and the typed `HLError` is re-thrown
/// (the store surfaces the offline state but STILL shows the crisis card on a
/// local positive item-9). `OutboxReplayService` drains the kind at reachability,
/// re-issuing the identical request under the persisted key (server `withIdempotency`
/// dedups a replay-after-landed within 24h).
///
/// **Append-only.** There is no DELETE / PATCH route for assessments — history is
/// read-only + append on the client.
public actor MentalHealthRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    private let swr: SWRCoordinator?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.swr = swr
    }

    // MARK: - Reads

    /// `GET /api/mental-health/assessments` — the caller's screener history,
    /// newest-first. Totals + bands + flags only; raw item answers are never
    /// returned. `instrument` filters server-side when set.
    ///
    /// **QOL-OFF-2:** the UNFILTERED first page (no instrument filter, `offset == 0`
    /// — the store's default read) routes through
    /// `swr.fetchCachingFirst(.mentalHealthHistory)` so the history is
    /// offline-readable. An instrument-filtered / paged read stays network-direct.
    public func history(
        instrument: MentalHealthInstrument? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [MentalHealthAssessmentDTO] {
        let api = api
        var query: [(String, String)] = [
            ("limit", String(limit)),
            ("offset", String(offset))
        ]
        if let instrument {
            query.append(("instrument", instrument.rawValue))
        }
        let frozenQuery = query
        @Sendable func networkFetch() async throws -> [MentalHealthAssessmentDTO] {
            let req: APIRequest<MentalHealthHistoryResponse> = .get("/api/mental-health/assessments", query: frozenQuery)
            return try await api.send(req).assessments
        }
        if let swr, instrument == nil, offset == 0 {
            return try await swr.fetchCachingFirst(
                .mentalHealthHistory,
                decoding: [MentalHealthAssessmentDTO].self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    // MARK: - Write (optimistic; idempotency-keyed; outbox-backed)

    /// `POST /api/mental-health/assessments`. Returns the server-authoritative
    /// result incl. the (item-9-gated) crisis set. Outbox-backed: on a retriable
    /// failure the create is durably enqueued under `key` and the typed `HLError`
    /// is re-thrown so the caller can surface the offline state — the crisis card
    /// is resolved separately from the LOCAL item-9 flag, never blocked on this.
    @discardableResult
    public func submit(_ body: CreateAssessmentRequest) async throws -> CreateAssessmentResponse {
        // #39 — bind the idempotency-key header to the body's `externalId` so the
        // header dedup (24h server window) and the durable `externalId` dedup
        // (no expiry) key on the SAME value: an outbox replay after >24h then
        // still collapses to one administration. Falls back to a fresh key only
        // for a legacy body with no externalId.
        let key = body.externalId.map { IdempotencyKey(raw: $0) } ?? IdempotencyKey()
        do {
            let req: APIRequest<CreateAssessmentResponse> = try .post(
                "/api/mental-health/assessments", body: body, idempotencyKey: key
            )
            let response = try await api.send(req)
            // Append-only: drop the cached history so the just-submitted row is
            // never masked by a fresh-enough cached snapshot on the store's reload.
            await swr?.invalidate([.mentalHealthHistory])
            return response
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueue(
                .createMentalHealthAssessment,
                payload: OutboxQueue.Payloads.CreateMentalHealthAssessment(body: body),
                key: key
            )
            throw err
        }
    }

    /// Replay drain for `createMentalHealthAssessment` — re-issues the identical
    /// POST under the persisted idempotency key (server dedups within 24h).
    public func replaySubmit(_ body: CreateAssessmentRequest, idempotencyKey: String) async throws {
        let req: APIRequest<CreateAssessmentResponse> = try .post(
            "/api/mental-health/assessments", body: body, idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    // MARK: - Outbox enqueue helper

    /// Persist a retriable failed write to the encrypted outbox under its
    /// idempotency key. The payload carries the (PHI) item answers ONLY inside the
    /// encrypted outbox blob until replay; a persistence failure is logged
    /// (sanitized, never the items) + swallowed; the original `HLError` is the one
    /// re-thrown (mirrors ``AllergiesRepository``).
    private func enqueue(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey
    ) async {
        do {
            let data = try encoder.encode(payload)
            try await outbox.enqueue(.init(kind: kind, payload: data, idempotencyKey: key.raw))
        } catch {
            HLLog.outbox.error("Mental-health outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
