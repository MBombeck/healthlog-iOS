import Foundation

/// **What actually happened to one mood write.**
///
/// Four outcomes, because three of them used to be one. `queued` and
/// `enqueueLost` both reach the user as "offline, we could not save that right
/// now"; they are the opposite of each other to anything that owns a cursor,
/// which is why the State-of-Mind importer could advance its anchor past a
/// sample no durable copy of ever existed.
enum MoodWriteOutcome: Sendable, Equatable {
    /// The server stored it. Terminal.
    case accepted(MoodEntry)
    /// The wire call failed retriably **and** the outbox row is confirmed
    /// written. Terminal for cursor purposes: the retry survives a relaunch.
    case queued(MoodEntry, transport: HLError)
    /// The wire call failed retriably and the durable write did **not** happen.
    /// Non-terminal: nothing may advance past this entry. The payload is the
    /// project's existing `HLError.notPersisted` —
    /// the honest "couldn't save", not the retriable transport error that would
    /// let a caller keep an optimistic "queued".
    case enqueueLost(HLError)
    /// The server refused it in a way a retry cannot fix.
    case rejected(HLError)

    /// Whether a caller may treat this write as accounted for.
    var isDurable: Bool {
        switch self {
        case .accepted, .queued: true
        case .enqueueLost, .rejected: false
        }
    }
}

public actor MoodRepository {
    private let api: APIClientProtocol
    private let outbox: OutboxQueue
    private let encoder: JSONEncoder
    /// SWR cache coordinator. When wired, `recent(days:)` routes
    /// through the `.moodEntries(days:)` row (cache-first on disk, 60s TTL,
    /// single-flighted revalidation) so the Stimmung card paints from disk on a
    /// warm foreground bounce + revalidates in the background — the same SWR
    /// posture as `MoodRelationsRepository`. Writes invalidate the row via
    /// `CacheInvalidator` (already wired). `nil` in unit tests → direct fetch.
    private let swr: SWRCoordinator?
    /// The zone the `from`/`to` day keys are cut in: the account's
    /// (``ProfileDay``), never the device's. Injectable for tests.
    private let profileTimeZone: @Sendable () -> TimeZone

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        swr: SWRCoordinator? = nil,
        profileTimeZone: @escaping @Sendable () -> TimeZone = { ProfileDay.timeZone }
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.profileTimeZone = profileTimeZone
        self.swr = swr
    }

    /// Page size per request — the server schema caps `limit` at 500
    /// (`listMoodEntriesSchema`). We page through with `offset`.
    private static let pageSize = 500
    /// Hard ceiling on pages to keep a runaway loop bounded
    /// (500 * 80 = 40 000 entries — far beyond any realistic history).
    private static let maxPages = 80

    /// Lädt die vollständige Mood-Historie der letzten `days` Tage.
    ///
    /// Der alte Code schickte nur `days=…`, einen Param den der
    /// Server **nicht** kennt (`listMoodEntriesSchema.safeParse` verwirft
    /// unbekannte Keys still) — und **kein** `limit`. Resultat: der Server gab
    /// seine Default-Page (100 neueste Einträge) zurück, Monate an Historie
    /// fehlten in der Heatmap / Year-in-Pixels / Stats.
    ///
    /// Fix: echte vom Server honorierte Params (`from`/`to` als `YYYY-MM-DD`,
    /// `limit`, `offset`) + Offset-Pagination bis `meta.total` gedrained ist
    /// (oder eine Page < `pageSize` zurückkommt). Cancellation-safe via `async`.
    /// The `from`/`to` pair for the last `days` days, as the
    /// account sees them: today is the account's today, and both keys are cut
    /// in `timeZone`. The server (`listMoodEntriesSchema`) reads the pair as
    /// days in the same zone, so a device-zone pair shifted the whole window
    /// by a day for anyone whose phone and account disagree.
    nonisolated static func dayWindow(days: Int, now: Date, timeZone: TimeZone) -> (from: String, to: String) {
        let to = ProfileDay.key(for: now, timeZone: timeZone)
        return (ProfileDay.key(to, addingDays: -max(days, 0)), to)
    }

    public func recent(days: Int = 365) async throws -> [MoodEntry] {
        // Server-Endpoint heißt `/api/mood-entries` (siehe API-Audit). The
        // paginated network fetch is captured as a sendable closure so it can be
        // routed through the SWR cache when a coordinator is wired.
        let api = api
        let window = Self.dayWindow(days: days, now: .now, timeZone: profileTimeZone())
        @Sendable func networkFetch() async throws -> [MoodEntry] {
            let (fromStr, toStr) = window

            var all: [MoodEntry] = []
            var offset = 0
            for _ in 0 ..< Self.maxPages {
                try Task.checkCancellation()
                let req: APIRequest<MoodListResponse> = .get(
                    "/api/mood-entries",
                    query: [
                        ("from", fromStr),
                        ("to", toStr),
                        ("limit", String(Self.pageSize)),
                        ("offset", String(offset))
                    ]
                )
                let response = try await api.send(req)
                all.append(contentsOf: response.entries)

                // Stop conditions: empty page, short page, or drained meta.total.
                if response.entries.count < Self.pageSize { break }
                if let total = response.meta?.total, all.count >= total { break }
                offset += response.entries.count
            }
            return all
        }
        // SWR: serve the `.moodEntries(days:)` row cache-first (60s
        // TTL) so a foreground bounce paints the card from disk without a cold
        // round-trip, and revalidate in the background. The key carries `days`
        // so the 365-day store window + a narrower drill-down never collide.
        if let swr {
            return try await swr.fetchCachingFirst(
                .moodEntries(days: days),
                decoding: [MoodEntry].self,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// The server's daily mood series (`GET /api/mood/analytics`),
    /// profile-zone day means plus summary slopes. Routed through
    /// the `.moodDailySeries` SWR row so a warm bounce and an offline launch
    /// paint the last server series; a mood write drops the row
    /// (`MutationKind.moodEntryChange`).
    func dailySeries(forceRevalidate: Bool = false) async throws -> MoodAnalyticsEnrichment? {
        let api = api
        @Sendable func networkFetch() async throws -> MoodAnalyticsEnrichment {
            let req: APIRequest<MoodAnalyticsEnrichment> = .get("/api/mood/analytics")
            return try await api.send(req)
        }
        if let swr {
            return try await swr.fetchCachingFirst(
                .moodDailySeries,
                decoding: MoodAnalyticsEnrichment.self,
                forceRevalidate: forceRevalidate,
                fetch: networkFetch
            )
        }
        return try await networkFetch()
    }

    /// Dedicated history read. Unlike `recent(days:)`, this preserves the
    /// server's page metadata and never participates in the analytics SWR row.
    public func history(query: MoodHistoryQuery) async throws -> MoodListResponse {
        let req: APIRequest<MoodListResponse> = .get(
            "/api/mood-entries",
            query: query.queryItems
        )
        return try await api.send(req)
    }

    /// Log a mood entry, throwing on anything that is not a server acceptance.
    ///
    /// Now a thin projection of
    /// ``logDurable(score:tags:tagKeys:note:recordedAt:retryIdentity:)``, which is
    /// where the difference between *queued* and *lost* lives. A queued write
    /// still throws the retriable transport error, exactly as before; a **lost**
    /// one now throws `HLError.notPersisted` instead of that same transport
    /// error, which is what every other write path in this app already does
    /// (`MeasurementsRepository+Writes`, `WorkoutsRepository`,
    /// `MedicationsRepository+ReminderIntake` — W-INTEGRITY-WRITEPATH G-2). Mood
    /// was the one repository that reported a permanently lost write as a
    /// retriable one.
    public func log(score: Int, tags: [String], tagKeys: [String] = [], note: String?, recordedAt: Date? = nil) async throws -> MoodEntry {
        switch await logDurable(
            score: score,
            tags: tags,
            tagKeys: tagKeys,
            note: note,
            recordedAt: recordedAt,
            retryIdentity: nil
        ) {
        case let .accepted(entry):
            return entry
        case let .queued(_, transport):
            throw transport
        case let .enqueueLost(notPersisted):
            throw notPersisted
        case let .rejected(error):
            throw error
        }
    }

    /// One mood write, with its durability stated rather than implied.
    ///
    /// The shipped path swallowed a failed outbox enqueue behind the transport
    /// error it was already about to throw, so "we queued it" and "we dropped it"
    /// reached the caller as the same event. That is survivable for a UI banner
    /// and fatal for an importer: the State-of-Mind anchor advanced past a sample
    /// whose only durable copy never existed.
    ///
    /// `retryIdentity` is the externally stable identity of the thing being
    /// written — a HealthKit sample UUID for the importer, `nil` for a manual
    /// entry that has none. When present, both the optimistic local id **and** the
    /// idempotency key are *derived* from it, so a relaunch that re-reads the same
    /// HealthKit sample rebuilds the same operation instead of minting a second row.
    func logDurable(
        score: Int,
        tags: [String],
        tagKeys: [String] = [],
        note: String?,
        recordedAt: Date? = nil,
        retryIdentity: HealthSyncRetryEnvelope?,
        appleHealthSampleID: String? = nil
    ) async -> MoodWriteOutcome {
        let stamp = recordedAt ?? .now
        var entry = MoodEntry(
            id: Self.localIdentifier(for: retryIdentity),
            recordedAt: stamp,
            score: score,
            tags: tags,
            tagKeys: tagKeys,
            note: note
        )
        // An Apple Health import carries its source pair, so a deletion in
        // Apple Health can reach it later (contract §3).
        if let appleHealthSampleID {
            entry = MoodEntry(
                id: entry.id,
                mood: entry.mood,
                tags: entry.tags,
                tagKeys: entry.tagKeys,
                moodLoggedAt: stamp,
                source: "APPLE_HEALTH",
                note: entry.note
            )
            entry.externalId = appleHealthSampleID
        }
        guard let retryIdentity else {
            return await logManual(entry, idempotencyKey: IdempotencyKey())
        }
        // The importer keeps its anchor until the sample is accepted or
        // queued and re-reads it otherwise, so its send stays ahead of the
        // queue: a stored row per attempt would only pile up under one key.
        let idempotencyKey = IdempotencyKey(raw: retryIdentity.idempotencyKey)
        do {
            return try await .accepted(postEntry(entry, idempotencyKey: idempotencyKey))
        } catch HLError.network(.writeCancelled) {
            // For the importer a cut-off request holds the anchor (the
            // sample is re-read next sweep).
            return .rejected(.canceled)
        } catch let err as HLError where err.shouldPersistToOutbox {
            guard let payload = try? encoder.encode(entry) else {
                return .enqueueLost(.notPersisted("mood entry could not be encoded for the outbox"))
            }
            let persisted = await enqueueDurably(
                kind: .logMood,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            )
            guard persisted else {
                return .enqueueLost(.notPersisted(String(describing: err)))
            }
            return .queued(entry, transport: err)
        } catch let err as HLError {
            return .rejected(err)
        } catch is CancellationError {
            // Stopped, not refused; the importer holds its anchor on it.
            return .rejected(.canceled)
        } catch {
            return .rejected(HLError.unknown(String(describing: error)))
        }
    }

    /// A manual entry has no second source to re-read it from, so it is
    /// stored before it is sent and removed once it has landed.
    private func logManual(_ entry: MoodEntry, idempotencyKey: IdempotencyKey) async -> MoodWriteOutcome {
        do {
            let payload = try encoder.encode(entry)
            let op = OutboxQueue.Operation(kind: .logMood, payload: payload, idempotencyKey: idempotencyKey.raw)
            let saved = try await outbox.writeAhead(op) { [self] in
                try await postEntry(entry, idempotencyKey: idempotencyKey)
            }
            return .accepted(saved)
        } catch let err as HLError {
            if case .notPersisted = err { return .enqueueLost(err) }
            return err.shouldPersistToOutbox ? .queued(entry, transport: err) : .rejected(err)
        } catch is CancellationError {
            return .rejected(.canceled)
        } catch {
            return .rejected(HLError.unknown(String(describing: error)))
        }
    }

    /// The optimistic local id of an entry that has not reached the server yet.
    ///
    /// Derived whenever there is something to derive from. The pre-Phase-07 path
    /// minted `local-<fresh UUID>` on *every* attempt, so two attempts at the same
    /// HealthKit sample produced two unrelated rows and a replay after relaunch
    /// could not resolve to the row the first attempt intended.
    private static func localIdentifier(for identity: HealthSyncRetryEnvelope?) -> String {
        guard let identity else { return "local-" + UUID().uuidString }
        return "local-" + identity.idempotencyKey
    }

    /// Writes one operation to the outbox and says whether it is actually there.
    ///
    /// The single place a mood write can become durable, so "queued" is one fact
    /// with one definition rather than three swallowed `catch` blocks.
    private func enqueueDurably(
        kind: OutboxQueue.Operation.Kind,
        payload: Data,
        idempotencyKey: String
    ) async -> Bool {
        do {
            try await outbox.enqueue(.init(kind: kind, payload: payload, idempotencyKey: idempotencyKey))
            return true
        } catch {
            // No value, no identifier — only the fact that the durable write did
            // not happen, which is what holds a caller's cursor.
            HLLog.outbox.error(
                "mood outbox write lost [\(kind.rawValue)] — caller holds: \(LogSanitizer.redact(String(describing: error)))"
            )
            return false
        }
    }

    public func replay(_ entry: MoodEntry, idempotencyKey: String) async throws -> MoodEntry {
        try await postEntry(entry, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// Delete a mood entry on the server.
    /// Server route: `DELETE /api/mood-entries/[id]` → 204 No Content.
    /// On retriable network failure, enqueues `deleteMood` on the outbox.
    public func delete(id: String) async throws {
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.DeleteMood(id: id))
        let op = OutboxQueue.Operation(kind: .deleteMood, payload: payload, idempotencyKey: idempotencyKey.raw)
        try await outbox.writeAhead(op) { [self] in
            try await deleteRequest(id: id, idempotencyKey: idempotencyKey)
        }
    }

    /// Outbox-replay path for `deleteMood`.
    public func replayDelete(id: String, idempotencyKey: String) async throws {
        try await deleteRequest(id: id, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// Update an existing mood entry. Server route:
    /// `PUT /api/mood-entries/[id]` → returns the updated entry. The item route
    /// exposes GET/PUT/DELETE only (no PATCH → 405); the `MoodEntryPatch` body is
    /// already PUT-valid (partial fields).
    /// On retriable network failure, enqueues `updateMood` on the outbox.
    public func update(id: String, patch: MoodEntryPatch) async throws -> MoodEntry {
        let idempotencyKey = IdempotencyKey()
        let payload = try encoder.encode(OutboxQueue.Payloads.UpdateMood(id: id, patch: patch))
        let op = OutboxQueue.Operation(kind: .updateMood, payload: payload, idempotencyKey: idempotencyKey.raw)
        return try await outbox.writeAhead(op) { [self] in
            try await patchRequest(id: id, patch: patch, idempotencyKey: idempotencyKey)
        }
    }

    /// Outbox-replay path for `updateMood`.
    public func replayUpdate(id: String, patch: MoodEntryPatch, idempotencyKey: String) async throws -> MoodEntry {
        try await patchRequest(id: id, patch: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// **Drop the SWR mood slices after a committed write.**
    /// `recent(days:)` routes reads through the `.moodEntries(days:)` row
    /// (cache-first, 60s TTL); before this, the doc CLAIMED "writes invalidate
    /// the row" but nothing did — a log/delete/update followed by a relaunch
    /// inside the TTL served the stale slice (missing the just-logged entry / or
    /// still showing the deleted one). Invalidating through the shared
    /// `MutationKind.moodEntryChange` matrix (which the audit flagged as DEAD —
    /// zero callers — and which now includes the 365-day window the store reads)
    /// makes the arm live and keeps the mood surfaces honest. No-op when no SWR
    /// coordinator is wired (unit tests).
    private func invalidateMoodCaches() async {
        await swr?.invalidate(MutationKind.moodEntryChange.affectedKeys)
    }

    private func deleteRequest(id: String, idempotencyKey: IdempotencyKey) async throws {
        let req: APIRequest<EmptyResponse> = .delete(
            "/api/mood-entries/\(id)",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(req)
        await invalidateMoodCaches()
    }

    private func patchRequest(id: String, patch: MoodEntryPatch, idempotencyKey: IdempotencyKey) async throws -> MoodEntry {
        // PUT (not PATCH): the server item route `/api/mood-entries/[id]` exports
        // GET/PUT/DELETE only — a PATCH returns 405 Method Not Allowed. The body
        // is identical (partial-field `MoodEntryPatch`), so the verb is the only
        // change. Both the live `update(...)` path and the outbox `replayUpdate`
        // route through here, so queued offline edits also replay as PUT.
        let req: APIRequest<MoodEntry> = try .put(
            "/api/mood-entries/\(id)",
            body: patch,
            idempotencyKey: idempotencyKey
        )
        let saved = try await api.send(req)
        await invalidateMoodCaches()
        return saved
    }

    /// Sends State of Mind samples deleted in Apple Health to the mood delete
    /// route; only entries imported with their source pair are touched.
    func deleteAppleHealthEntries(_ externalIDs: [String]) async throws {
        guard !externalIDs.isEmpty else { return }
        let req: APIRequest<EmptyResponse> = try .delete(
            AppleHealthDeleteDomain.mood.path,
            body: ExternalIDBatch(externalIds: externalIDs)
        )
        _ = try await api.send(req)
        await invalidateMoodCaches()
    }

    private func postEntry(_ entry: MoodEntry, idempotencyKey: IdempotencyKey) async throws -> MoodEntry {
        let req: APIRequest<MoodEntry> = try .post(
            "/api/mood-entries",
            body: entry,
            idempotencyKey: idempotencyKey
        )
        let saved = try await api.send(req)
        await invalidateMoodCaches()
        return saved
    }
}

public struct MoodListResponse: Codable, Sendable {
    public let entries: [MoodEntry]
    public let meta: MeasurementListResponse.ListMeta?
}
