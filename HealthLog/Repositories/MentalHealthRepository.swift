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
    /// The UNFILTERED first page (no instrument filter, `offset == 0`
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
            guard offset == 0 else {
                let req: APIRequest<MentalHealthHistoryResponse> = .get("/api/mental-health/assessments", query: frozenQuery)
                return try await api.send(req).assessments
            }
            // #147 (v1.43.7) — a first-page read goes on with `offset`
            // while `meta.truncated`, so the history is whole.
            return try await CappedListReader.readAllPages(
                api: api,
                path: "/api/mental-health/assessments",
                query: frozenQuery
            ) { (page: MentalHealthHistoryResponse) in page.assessments }
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

    /// `GET /api/mental-health/assessments/{id}` — one administration with
    /// its answers (server v1.48). Network-direct and never cached: the
    /// answers are PHI and only ever held for the screen that shows them.
    public func assessment(id: String) async throws -> MentalHealthAssessmentDetailDTO {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let req: APIRequest<MentalHealthAssessmentDetailDTO> = .get("/api/mental-health/assessments/\(encoded)")
        return try await api.send(req)
    }

    // MARK: - Write (optimistic; idempotency-keyed; outbox-backed)

    /// `POST /api/mental-health/assessments`. Returns the server-authoritative
    /// result incl. the (item-9-gated) crisis set. Outbox-backed: on a retriable
    /// failure the create is durably enqueued under `key` and the typed `HLError`
    /// is re-thrown so the caller can surface the offline state — the crisis card
    /// is resolved separately from the LOCAL item-9 flag, never blocked on this.
    @discardableResult
    public func submit(_ body: CreateAssessmentRequest) async throws -> CreateAssessmentResponse {
        // Bind the idempotency-key header to the body's `externalId` so the
        // header dedup (24h server window) and the durable `externalId` dedup
        // (no expiry) key on the SAME value: an outbox replay after >24h then
        // still collapses to one administration. Falls back to a fresh key only
        // for a legacy body with no externalId.
        let key = body.externalId.map { IdempotencyKey(raw: $0) } ?? IdempotencyKey()
        return try await writeAhead(
            .createMentalHealthAssessment,
            payload: OutboxQueue.Payloads.CreateMentalHealthAssessment(body: body),
            key: key
        ) { [self] in
            let req: APIRequest<CreateAssessmentResponse> = try .post(
                "/api/mental-health/assessments", body: body, idempotencyKey: key
            )
            let response = try await api.send(req)
            // Append-only: drop the cached history so the just-submitted row is
            // never masked by a fresh-enough cached snapshot on the store's reload.
            await swr?.invalidate([.mentalHealthHistory])
            return response
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

    // MARK: - Outbox write-ahead helper

    /// Stores the write before it is sent and removes it once it has landed
    /// (``OutboxQueue/writeAhead(_:now:send:)``). A send that fails with no
    /// stored copy behind it surfaces as `HLError.notPersisted`, so the caller
    /// rolls back instead of reporting the write as queued.
    private func writeAhead<Result: Sendable>(
        _ kind: OutboxQueue.Operation.Kind,
        payload: some Encodable & Sendable,
        key: IdempotencyKey,
        send: @Sendable () async throws -> Result
    ) async throws -> Result {
        let data = try encoder.encode(payload)
        let op = OutboxQueue.Operation(kind: kind, payload: data, idempotencyKey: key.raw)
        return try await outbox.writeAhead(op, send: send)
    }
}
