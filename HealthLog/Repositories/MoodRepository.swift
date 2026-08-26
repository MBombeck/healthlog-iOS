import Foundation

/// **Phase 07 / plan 07-05 — what actually happened to one mood write.**
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
    /// project's existing `HLError.notPersisted` (W-INTEGRITY-WRITEPATH G-2) —
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
    /// v0.11 W2 — standalone read-union seam. `nil` (default) → existing server
    /// path verbatim (paired invariant). Non-nil + live standalone → reads/writes
    /// route to the local mirror; no `/api/*` fires.
    private let standalone: StandaloneGate?
    /// v0.14.3 E3 — SWR cache coordinator. When wired, `recent(days:)` routes
    /// through the `.moodEntries(days:)` row (cache-first on disk, 60s TTL,
    /// single-flighted revalidation) so the Stimmung card paints from disk on a
    /// warm foreground bounce + revalidates in the background — the same SWR
    /// posture as `MoodRelationsRepository`. Writes invalidate the row via
    /// `CacheInvalidator` (already wired). `nil` in unit tests → direct fetch.
    private let swr: SWRCoordinator?

    public init(
        api: APIClientProtocol,
        outbox: OutboxQueue,
        encoder: JSONEncoder = .hlDefault,
        standalone: StandaloneGate? = nil,
        swr: SWRCoordinator? = nil
    ) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
        self.standalone = standalone
        self.swr = swr
    }

    private var isStandalone: Bool {
        standalone?.isActive == true
    }

    /// Page size per request — the server schema caps `limit` at 500
    /// (`listMoodEntriesSchema`). We page through with `offset`.
    private static let pageSize = 500
    /// Hard ceiling on pages to keep a runaway loop bounded
    /// (500 * 80 = 40 000 entries — far beyond any realistic history).
    private static let maxPages = 80

    /// Lädt die vollständige Mood-Historie der letzten `days` Tage.
    ///
    /// B16 (v0.10.0): Der alte Code schickte nur `days=…`, einen Param den der
    /// Server **nicht** kennt (`listMoodEntriesSchema.safeParse` verwirft
    /// unbekannte Keys still) — und **kein** `limit`. Resultat: der Server gab
    /// seine Default-Page (100 neueste Einträge) zurück, Monate an Historie
    /// fehlten in der Heatmap / Year-in-Pixels / Stats.
    ///
    /// Fix: echte vom Server honorierte Params (`from`/`to` als `YYYY-MM-DD`,
    /// `limit`, `offset`) + Offset-Pagination bis `meta.total` gedrained ist
    /// (oder eine Page < `pageSize` zurückkommt). Cancellation-safe via `async`.
    public func recent(days: Int = 365) async throws -> [MoodEntry] {
        if isStandalone, let standalone {
            // Standalone: read the local mirror, newest-first. Mood *analytics*
            // (heatmap/stability/correlations) are already client-computed from
            // these entries (`MoodInsights.compute`), so the whole surface is
            // offline once the entries come from here.
            let snaps = try await standalone.local.standaloneMoods(days: days)
            return snaps.map { $0.toDomainMood() }
        }
        // Server-Endpoint heißt `/api/mood-entries` (siehe API-Audit). The
        // paginated network fetch is captured as a sendable closure so it can be
        // routed through the SWR cache (v0.14.3 E3) when a coordinator is wired.
        let api = api
        @Sendable func networkFetch() async throws -> [MoodEntry] {
            let to = Date.now
            let from = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: to) ?? to

            let fmt = DateFormatter()
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = .current
            fmt.dateFormat = "yyyy-MM-dd"
            let fromStr = fmt.string(from: from)
            let toStr = fmt.string(from: to)

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
        // v0.14.3 E3 — SWR: serve the `.moodEntries(days:)` row cache-first (60s
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

    /// Dedicated history read. Unlike `recent(days:)`, this preserves the
    /// server's page metadata and never participates in the analytics SWR row.
    public func history(query: MoodHistoryQuery) async throws -> MoodListResponse {
        if isStandalone, let standalone {
            let snapshots = try await standalone.local.standaloneMoods(days: nil)
            let matching = snapshots
                .map {
                    MoodEntry(
                        id: $0.externalId,
                        mood: ServerMoodLevel(score: $0.score),
                        tags: $0.tags,
                        tagKeys: $0.tagKeys,
                        moodLoggedAt: $0.recordedAt,
                        source: $0.source.uppercased(),
                        note: $0.note
                    )
                }
                .filter { query.matches($0) }
                .sorted { $0.recordedAt > $1.recordedAt }
            let start = min(query.offset, matching.count)
            let end = min(start + query.limit, matching.count)
            return MoodListResponse(
                entries: Array(matching[start ..< end]),
                meta: MeasurementListResponse.ListMeta(
                    total: matching.count,
                    limit: query.limit,
                    offset: query.offset
                )
            )
        }

        let req: APIRequest<MoodListResponse> = .get(
            "/api/mood-entries",
            query: query.queryItems
        )
        return try await api.send(req)
    }

    /// Log a mood entry, throwing on anything that is not a server acceptance.
    ///
    /// **Phase 07 / plan 07-05.** Now a thin projection of
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
        retryIdentity: HealthSyncRetryEnvelope?
    ) async -> MoodWriteOutcome {
        let stamp = recordedAt ?? .now
        if isStandalone, let standalone {
            do {
                let snap = try await standalone.local.standaloneAddMood(
                    score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: stamp
                )
                return .accepted(snap.toDomainMood())
            } catch {
                return .rejected(HLError.unknown(String(describing: error)))
            }
        }
        let entry = MoodEntry(
            id: Self.localIdentifier(for: retryIdentity),
            recordedAt: stamp,
            score: score,
            tags: tags,
            tagKeys: tagKeys,
            note: note
        )
        let idempotencyKey = retryIdentity.map { IdempotencyKey(raw: $0.idempotencyKey) } ?? IdempotencyKey()
        do {
            return try await .accepted(postEntry(entry, idempotencyKey: idempotencyKey))
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
        if isStandalone, let standalone {
            try await standalone.local.standaloneDeleteMood(externalId: id)
            return
        }
        let idempotencyKey = IdempotencyKey()
        do {
            try await deleteRequest(id: id, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.DeleteMood(id: id))
            guard await enqueueDurably(kind: .deleteMood, payload: payload, idempotencyKey: idempotencyKey.raw) else {
                // G-2: the send failed AND the durable write failed. Surfacing
                // the retriable error would leave the caller believing a delete
                // is queued that no longer exists anywhere.
                throw HLError.notPersisted(String(describing: err))
            }
            throw err
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
        if isStandalone, let standalone {
            // Read the current row to fill any field the patch leaves nil
            // (the local store's update is a full replace).
            let current = try await standalone.local.standaloneMoods(days: nil)
                .first { $0.externalId == id }
            let score = patch.mood?.score ?? current?.score ?? 3
            let tags = patch.tags ?? current?.tags ?? []
            let tagKeys = patch.tagKeys ?? current?.tagKeys ?? []
            let note = patch.note ?? current?.note
            let recordedAt = patch.moodLoggedAt ?? current?.recordedAt ?? .now
            try await standalone.local.standaloneUpdateMood(
                externalId: id, score: score, tags: tags, tagKeys: tagKeys, note: note, recordedAt: recordedAt
            )
            return MoodEntry(id: id, recordedAt: recordedAt, score: score, tags: tags, tagKeys: tagKeys, note: note)
        }
        let idempotencyKey = IdempotencyKey()
        do {
            return try await patchRequest(id: id, patch: patch, idempotencyKey: idempotencyKey)
        } catch let err as HLError where err.shouldPersistToOutbox {
            let payload = try encoder.encode(OutboxQueue.Payloads.UpdateMood(id: id, patch: patch))
            guard await enqueueDurably(kind: .updateMood, payload: payload, idempotencyKey: idempotencyKey.raw) else {
                // G-2, as above.
                throw HLError.notPersisted(String(describing: err))
            }
            throw err
        }
    }

    /// Outbox-replay path for `updateMood`.
    public func replayUpdate(id: String, patch: MoodEntryPatch, idempotencyKey: String) async throws -> MoodEntry {
        try await patchRequest(id: id, patch: patch, idempotencyKey: IdempotencyKey(raw: idempotencyKey))
    }

    /// **audit-v0162 M-2 — drop the SWR mood slices after a committed write.**
    /// `recent(days:)` routes reads through the `.moodEntries(days:)` row
    /// (cache-first, 60s TTL); before this, the doc CLAIMED "writes invalidate
    /// the row" but nothing did — a log/delete/update followed by a relaunch
    /// inside the TTL served the stale slice (missing the just-logged entry / or
    /// still showing the deleted one). Invalidating through the shared
    /// `MutationKind.moodEntryChange` matrix (which the audit flagged as DEAD —
    /// zero callers — and which now includes the 365-day window the store reads)
    /// makes the arm live and keeps the mood surfaces honest. No-op when no SWR
    /// coordinator is wired (unit tests / standalone).
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
