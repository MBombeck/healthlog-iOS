import Foundation

/// Actor repository for the v1.15 LOCKED cycle-tracking contract. Clones the
/// `MoodRepository` posture exactly: optimistic write → server → on retriable
/// failure enqueue the matching Outbox kind; SWR cache-first reads; a clean
/// `cycle.disabled` (403) surface so a non-enabled account renders the disabled
/// state instead of a hard error.
///
/// Everything here stays dormant behind `FeatureFlag.cycleTracking` (the store +
/// gate above it never call into the repo while the flag is off). No UI yet.
public actor CycleRepository {
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

    /// Bulk drain cap (server `bulk` route caps at 500).
    public static let bulkCap = 500

    /// True when an `HLError` is the server's `403 cycle.disabled` envelope.
    /// Callers map this to the disabled surface (no retry, no outbox).
    public nonisolated static func isCycleDisabled(_ error: Error) -> Bool {
        if case let HLError.server(status, code, _) = error {
            return status == 403 && code == "cycle.disabled"
        }
        return false
    }

    // MARK: - Reads (SWR cache-first)

    /// `GET /api/cycle/calendar?from&to`. `dayAnchor` is the user-tz `YYYY-MM-DD`
    /// so a new day is a structural cache-miss (a prior-day "today" highlight can
    /// never carry across midnight).
    public func calendar(from: String, to: String, dayAnchor: String) async throws -> CycleCalendarResponse {
        let api = api
        @Sendable func networkFetch() async throws -> CycleCalendarResponse {
            let req: APIRequest<CycleCalendarResponse> = .get(
                "/api/cycle/calendar",
                query: [("from", from), ("to", to)]
            )
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .cycleCalendar(from: from, to: to, day: dayAnchor),
                decoding: CycleCalendarResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/cycle/cycles?limit`.
    public func cycles(limit: Int = 24) async throws -> CycleListResponse {
        let api = api
        @Sendable func networkFetch() async throws -> CycleListResponse {
            let req: APIRequest<CycleListResponse> = .get(
                "/api/cycle/cycles",
                query: [("limit", String(limit))]
            )
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .cycleCycles(limit: limit),
                decoding: CycleListResponse.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/cycle/profile`.
    public func profile() async throws -> CycleProfileDTO {
        let api = api
        @Sendable func networkFetch() async throws -> CycleProfileDTO {
            let req: APIRequest<CycleProfileDTO> = .get("/api/cycle/profile")
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .cycleProfile,
                decoding: CycleProfileDTO.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// `GET /api/cycle/day-logs?date=YYYY-MM-DD` returns the canonical row or
    /// JSON `null` when the day has not been logged.
    public func dayLog(date: String) async throws -> CycleDayLogDTO? {
        let request: APIRequest<CycleDayLogDTO> = .get(
            "/api/cycle/day-logs",
            query: [("date", date)]
        )
        return try await api.sendEnvelope(request).data
    }

    public func customSymptoms() async throws -> [CycleCustomSymptomDTO] {
        let api = api
        @Sendable func networkFetch() async throws -> CycleCustomSymptomsResponse {
            let request: APIRequest<CycleCustomSymptomsResponse> = .get("/api/cycle/symptoms/custom")
            return try await api.send(request)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .cycleCustomSymptoms,
                decoding: CycleCustomSymptomsResponse.self,
                fetch: networkFetch
            ).symptoms
        }
        return try await networkFetch().symptoms
    }

    /// The compute-heavy endpoint is protected by both SWR and a store-level
    /// one-shot guard so a view remount cannot consume the 30/min allowance.
    public func insights() async throws -> CycleInsightsDTO {
        let api = api
        @Sendable func networkFetch() async throws -> CycleInsightsDTO {
            let request: APIRequest<CycleInsightsDTO> = .get("/api/cycle/insights")
            return try await api.send(request)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .cycleInsights,
                decoding: CycleInsightsDTO.self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    // MARK: - Writes (optimistic + outbox)

    /// Single day-log capture. Optimistic `POST /api/cycle/day-logs`; on a
    /// retriable failure enqueue `logCycleDayLog` (drains via bulk) carrying the
    /// same `externalId` + idempotency key so replay is idempotent.
    @discardableResult
    public func logDayLog(_ write: CycleDayLogWrite) async throws -> CycleDayLogDTO {
        let idempotencyKey = IdempotencyKey()
        do {
            let req: APIRequest<CycleDayLogDTO> = try .post(
                "/api/cycle/day-logs",
                body: write,
                idempotencyKey: idempotencyKey
            )
            let result = try await api.send(req)
            await invalidateTimeline()
            return result
        } catch let err as HLError where err.shouldPersistToOutbox {
            try await enqueue(.logCycleDayLog, OutboxQueue.Payloads.LogCycleDayLog(write: write), idempotencyKey)
            throw err
        }
    }

    /// Tri-state edit path. PATCH accepts explicit nulls while POST does not.
    /// Retriable failures preserve that exact PATCH shape in the Outbox.
    @discardableResult
    public func updateDayLog(id: String, patch: CycleDayLogPatch) async throws -> CycleDayLogDTO {
        let idempotencyKey = IdempotencyKey()
        do {
            return try await patchDayLog(id: id, patch: patch, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            try await enqueue(
                .updateCycleDayLog,
                OutboxQueue.Payloads.UpdateCycleDayLog(id: id, patch: patch),
                idempotencyKey
            )
            throw err
        }
    }

    /// `DELETE /api/cycle/day-logs/{id}` (soft). On retriable failure enqueue.
    public func deleteDayLog(id: String) async throws {
        let idempotencyKey = IdempotencyKey()
        do {
            try await deleteDayLogRequest(id: id, idempotencyKey: idempotencyKey)
            await invalidateTimeline()
        } catch let err as HLError where err.shouldPersistToOutbox {
            try await enqueue(.deleteCycleDayLog, OutboxQueue.Payloads.DeleteCycleDayLog(id: id), idempotencyKey)
            throw err
        }
    }

    /// `DELETE /api/cycle/cycles/{id}` (soft).
    public func deleteCycle(id: String) async throws {
        let req: APIRequest<EmptyResponse> = .delete("/api/cycle/cycles/\(id)")
        _ = try await api.send(req)
        await invalidateTimeline()
    }

    /// One-tap `POST /api/cycle/period`. On retriable failure enqueue.
    public func period(_ request: CyclePeriodRequest) async throws {
        let idempotencyKey = IdempotencyKey()
        do {
            let req: APIRequest<EmptyResponse> = try .post(
                "/api/cycle/period",
                body: request,
                idempotencyKey: idempotencyKey
            )
            _ = try await api.send(req)
            await invalidateTimeline()
        } catch let err as HLError where err.shouldPersistToOutbox {
            try await enqueue(.cyclePeriod, OutboxQueue.Payloads.CyclePeriod(request: request), idempotencyKey)
            throw err
        }
    }

    /// `PATCH /api/auth/me/cycle-prefs` — deep-merge; returns the merged profile.
    @discardableResult
    public func updatePrefs(_ patch: CyclePrefsPatch) async throws -> CycleProfileDTO {
        let req: APIRequest<CycleProfileDTO> = try .patch("/api/auth/me/cycle-prefs", body: patch)
        let result = try await api.send(req)
        await invalidateProfileAndCalendar()
        return result
    }

    @discardableResult
    public func createCustomSymptom(_ create: CycleCustomSymptomCreate) async throws -> CycleCustomSymptomDTO {
        let request: APIRequest<CycleCustomSymptomDTO> = try .post(
            "/api/cycle/symptoms/custom",
            body: create
        )
        let result = try await api.send(request)
        await swr?.invalidate([.cycleCustomSymptoms, .cycleInsights])
        return result
    }

    @discardableResult
    public func updateCustomSymptom(
        key: String,
        patch: CycleCustomSymptomPatch
    ) async throws -> CycleCustomSymptomDTO {
        let request: APIRequest<CycleCustomSymptomDTO> = try .patch(
            "/api/cycle/symptoms/custom/\(key)",
            body: patch
        )
        let result = try await api.send(request)
        await swr?.invalidate([.cycleCustomSymptoms, .cycleInsights])
        return result
    }

    /// History-preserving delete. Never adds `purge=true`.
    @discardableResult
    public func softDeleteCustomSymptom(key: String) async throws -> CycleCustomSymptomDeleteResponse {
        let request: APIRequest<CycleCustomSymptomDeleteResponse> = .delete(
            "/api/cycle/symptoms/custom/\(key)"
        )
        let result = try await api.send(request)
        await swr?.invalidate([.cycleCustomSymptoms, .cycleInsights])
        return result
    }

    public func invalidateInsights() async {
        await swr?.invalidate([.cycleInsights])
    }

    // MARK: - The stored verdict (Z1 / #72)

    /// Persist the last server-resolved verdict so an offline start can show the
    /// last known assessment WITH its date instead of computing a fresh one on a
    /// device that may not hold the profile timezone.
    ///
    /// Deliberately its own key rather than a re-read of the cached calendar:
    /// `.cycleCalendar` is day-anchored (a new day is a structural miss by
    /// design), and the day the calendar cache disappears is exactly the day an
    /// offline device needs the previous verdict.
    public func persistVerdict(_ snapshot: CycleVerdictSnapshot) async {
        await swr?.writeThrough(.cycleVerdict, value: snapshot)
    }

    /// The last persisted verdict, or `nil` when none was ever stored. Cache-only
    /// — never kicks a network call.
    public func storedVerdict() async -> CycleVerdictSnapshot? {
        await swr?.peek(.cycleVerdict, as: CycleVerdictSnapshot.self)?.value
    }

    /// `DELETE /api/cycle/all` — hard purge. It is deliberately not
    /// Outbox-backed; offline the call fails honestly. Successful purges
    /// invalidate every persisted cycle snapshot.
    @discardableResult
    public func purgeAll() async throws -> CyclePurgeResponse {
        let req: APIRequest<CyclePurgeResponse> = .delete("/api/cycle/all")
        let response = try await api.send(req)
        let window = CycleCalendarWindow.default
        await swr?.invalidate([
            .cycleCalendar(from: window.from, to: window.to, day: window.dayAnchor),
            .cycleCycles(limit: 24),
            .cycleProfile,
            .cycleCustomSymptoms,
            .cycleInsights,
            // The purge promise is "no dated reproductive trace survives" — a
            // stored verdict carries a cycle start date and a day count.
            .cycleVerdict
        ])
        return response
    }

    // MARK: - Bulk drain (Outbox + HealthKit target)

    /// `POST /api/cycle/day-logs/bulk` — the Outbox + HealthKit drain. Capped at
    /// `bulkCap` (500); returns per-entry results. `withIdempotency` via the
    /// per-flush key. Caller chunks anything over the cap.
    @discardableResult
    public func bulk(_ entries: [CycleDayLogWrite], idempotencyKey: IdempotencyKey = IdempotencyKey()) async throws -> CycleBulkResponse {
        precondition(entries.count <= Self.bulkCap, "cycle bulk drain capped at \(Self.bulkCap)")
        let req: APIRequest<CycleBulkResponse> = try .post(
            "/api/cycle/day-logs/bulk",
            body: CycleBulkRequest(entries: entries),
            idempotencyKey: idempotencyKey
        )
        return try await api.send(req)
    }

    // MARK: - Outbox replay paths

    public func replayLogDayLog(write: CycleDayLogWrite, idempotencyKey: String) async throws {
        // Drain through the bulk endpoint (single entry) — the externalId UPSERT
        // makes a doubly-delivered replay idempotent server-side.
        _ = try await bulk([write], idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    @discardableResult
    public func replayUpdateDayLog(id: String, patch: CycleDayLogPatch, idempotencyKey: String) async throws -> CycleDayLogDTO {
        try await patchDayLog(id: id, patch: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    public func replayDeleteDayLog(id: String, idempotencyKey: String) async throws {
        try await deleteDayLogRequest(id: id, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    public func replayPeriod(request: CyclePeriodRequest, idempotencyKey: String) async throws {
        let req: APIRequest<EmptyResponse> = try .post(
            "/api/cycle/period",
            body: request,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        _ = try await api.send(req)
    }

    private func invalidateTimeline() async {
        let window = CycleCalendarWindow.default
        await swr?.invalidate([
            .cycleCalendar(from: window.from, to: window.to, day: window.dayAnchor),
            .cycleCycles(limit: 24),
            .cycleInsights
        ])
    }

    private func invalidateProfileAndCalendar() async {
        let window = CycleCalendarWindow.default
        await swr?.invalidate([
            .cycleProfile,
            .cycleCalendar(from: window.from, to: window.to, day: window.dayAnchor),
            .cycleInsights
        ])
    }

    // MARK: - Private request helpers

    private func patchDayLog(id: String, patch: CycleDayLogPatch, idempotencyKey: IdempotencyKey) async throws -> CycleDayLogDTO {
        let req: APIRequest<CycleDayLogDTO> = try .patch(
            "/api/cycle/day-logs/\(id)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let result = try await api.send(req)
        await invalidateTimeline()
        return result
    }

    private func deleteDayLogRequest(id: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/cycle/day-logs/\(id)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
        await invalidateTimeline()
    }

    /// **Phase 07 / plan 07-06 — the durable landing place for an imported
    /// day-log the server did not terminally accept.**
    ///
    /// Two things separate it from the private `enqueue` above, and both are the
    /// point. It is **owner-bound**: the row is stamped with, and validated
    /// against, the account the importer was admitted for, so a write captured
    /// under A can never be replayed under B. And it **throws when the durable
    /// write is lost** rather than logging and returning — "we queued it" and
    /// "we lost it" are opposite facts to a caller that owns a cursor, and a
    /// repository that reports both the same way cannot be used by an importer.
    func enqueueDurableDayLog(
        _ write: CycleDayLogWrite,
        idempotencyKey: String,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        let data = try encoder.encode(OutboxQueue.Payloads.LogCycleDayLog(write: write))
        try await outbox.enqueue(
            .init(
                kind: .logCycleDayLog,
                payload: data,
                idempotencyKey: idempotencyKey,
                ownerUserID: ownerUserID
            ),
            requiringCurrentOwner: ownerUserID
        )
    }

    private func enqueue(_ kind: OutboxQueue.Operation.Kind, _ payload: some Encodable & Sendable, _ key: IdempotencyKey) async throws {
        let data = try encoder.encode(payload)
        do {
            try await outbox.enqueue(.init(kind: kind, payload: data, idempotencyKey: key.raw))
        } catch {
            HLLog.outbox.error("Outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
