import Foundation

/// Wraps the coach self-context endpoints (server v1.16.0 —
/// `src/app/api/coach/about-me/route.ts`):
///
/// - `GET /api/coach/about-me` → stored self-context + pending clarifying
///   questions + the server's field caps.
/// - `PUT /api/coach/about-me` → write (or clear) the self-context; echoes
///   the effective state including freshly derived questions.
///
/// Plain JSON over the wire — encryption happens server-side at rest. The
/// PUT rides the standard `.put` factory, so an `Idempotency-Key` travels on
/// every write like the rest of the app's mutations. No SWR cache: the
/// surface is a small Settings editor that loads on open (read-fresh), and
/// the text is sensitive enough that not persisting a local copy is the
/// better default.
public actor CoachAboutMeRepository {
    private let api: APIClientProtocol
    /// Outbox seam for the clarifying-question writes (adopt / dismiss). The
    /// GET/PUT editor path stays unqueued (the editor surfaces its own save
    /// error and the user can simply retry), but the adopt/dismiss actions are
    /// fire-and-forget from the chat / questions UI, so a retriable failure is
    /// parked for replay under the same idempotency key. `nil` in the unit
    /// tests that only exercise the wire contract.
    private let outbox: OutboxQueue?
    private let encoder: JSONEncoder

    /// **CU-20 (#69)** — last `updatedAt` seen from `/api/coach/about-me`.
    ///
    /// This is the ONE route of the eight whose token is **not** the shared
    /// `User.updatedAt`: it guards `UserHealthProfile.updatedAt`, its own table
    /// (`api/coach/about-me/route.ts:237-240`), so unrelated account writes do
    /// not perturb it and the 409-loop hazard that afflicts the other seven
    /// does not apply here.
    private var baseUpdatedAt: String?

    public init(api: APIClientProtocol, outbox: OutboxQueue? = nil, encoder: JSONEncoder = .hlDefault) {
        self.api = api
        self.outbox = outbox
        self.encoder = encoder
    }

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentAboutMeToken() -> String? {
        baseUpdatedAt
    }

    /// Fetch the caller's stored self-context.
    ///
    /// **CU-20 special case 7c:** this GET returns `updatedAt: null` (an
    /// explicit null, not an omitted key) when the profile row has never been
    /// written — `UserHealthProfile` is a separate table that does not exist
    /// until the first save (`route.ts:104-116`). A null decodes to `nil`
    /// here, and the first write then omits `baseUpdatedAt` entirely, taking
    /// the server's `upsert` arm. Sending a literal `null` would instead be a
    /// hard `422 invalid_base_updated_at`.
    public func get() async throws -> CoachAboutMeDTO {
        let request: APIRequest<CoachAboutMeDTO> = .get("/api/coach/about-me")
        let dto = try await api.send(request)
        baseUpdatedAt = dto.updatedAt
        return dto
    }

    /// Write the self-context (all four fields, empty = clear). Returns the
    /// server echo — the effective state plus newly derived
    /// `pendingQuestions`.
    ///
    /// **CU-20:** guarded by `baseUpdatedAt`; a conflict returns
    /// `409 about_me_conflict` having written nothing, and the bounded retry
    /// re-reads and re-sends. Note the server treats a *deleted* profile row
    /// specially: a PUT carrying a token whose row has since vanished does not
    /// 409, it re-creates the row (`route.ts:246-257`).
    ///
    /// **`aboutMe` is no longer required server-side** — see
    /// ``CoachAboutMeWrite``. There is no client-side mandatory check to trip
    /// over; all four fields are always sent, empty meaning "clear".
    @discardableResult
    public func update(_ write: CoachAboutMeWrite) async throws -> CoachAboutMeDTO {
        try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.aboutMe,
            token: baseUpdatedAt
        ) { token in
            let request: APIRequest<CoachAboutMeDTO> = try .put(
                "/api/coach/about-me",
                body: OptimisticWriteBody(payload: write, baseUpdatedAt: token)
            )
            let echoed = try await api.send(request)
            baseUpdatedAt = echoed.updatedAt
            return echoed
        } reread: {
            // The editor's four drafts are a full replace, so the pending write
            // is still exactly what the user asked for; only the token moves.
            try await get().updatedAt
        }
    }

    // MARK: - Clarifying-question loop (COACH-3)

    /// Adopt a clarifying-question answer (or a "remember this" chat
    /// statement) into the matching structured self-context field
    /// (`POST /api/coach/about-me/adopt`). Optimistic + outbox-backed: on a
    /// *retriable* failure the write lands on the queue under the same
    /// idempotency key (server dedupes the replay against the stored prose)
    /// and the error re-throws so the caller can surface it. The endpoint does
    /// NOT echo the updated self-context — the caller re-`get()`s to refresh
    /// the fields + freshly derived questions.
    @discardableResult
    public func adopt(_ write: CoachAboutMeAdoptWrite) async throws -> CoachAboutMeAdoptResult {
        try await adopt(write, idempotencyKey: IdempotencyKey())
    }

    @discardableResult
    public func adopt(
        _ write: CoachAboutMeAdoptWrite,
        idempotencyKey: IdempotencyKey
    ) async throws -> CoachAboutMeAdoptResult {
        do {
            let request: APIRequest<CoachAboutMeAdoptResult> = try .post(
                "/api/coach/about-me/adopt",
                body: write,
                idempotencyKey: idempotencyKey
            )
            return try await api.send(request)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueueAdopt(write, idempotencyKey: idempotencyKey)
            throw err
        }
    }

    /// Dismiss one pending clarifying question by exact text (omit `question`
    /// to dismiss all) — `DELETE /api/coach/about-me/questions`. Optimistic +
    /// outbox-backed like `adopt`. Returns the remaining pending questions.
    @discardableResult
    public func dismissQuestion(_ write: CoachAboutMeDismissWrite) async throws -> CoachAboutMeQuestionsResult {
        try await dismissQuestion(write, idempotencyKey: IdempotencyKey())
    }

    @discardableResult
    public func dismissQuestion(
        _ write: CoachAboutMeDismissWrite,
        idempotencyKey: IdempotencyKey
    ) async throws -> CoachAboutMeQuestionsResult {
        do {
            let request: APIRequest<CoachAboutMeQuestionsResult> = try .delete(
                "/api/coach/about-me/questions",
                body: write,
                idempotencyKey: idempotencyKey
            )
            return try await api.send(request)
        } catch let err as HLError where err.shouldPersistToOutbox {
            await enqueueDismiss(write, idempotencyKey: idempotencyKey)
            throw err
        }
    }

    // MARK: - Outbox replay entry points

    /// Re-issues the adopt POST with the persisted key (no enqueue-on-failure —
    /// the replay loop owns retry bookkeeping).
    @discardableResult
    public func replayAdopt(
        _ write: CoachAboutMeAdoptWrite,
        idempotencyKey: String
    ) async throws -> CoachAboutMeAdoptResult {
        let request: APIRequest<CoachAboutMeAdoptResult> = try .post(
            "/api/coach/about-me/adopt",
            body: write,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(request)
    }

    /// Re-issues the dismiss DELETE with the persisted key.
    @discardableResult
    public func replayDismiss(
        _ write: CoachAboutMeDismissWrite,
        idempotencyKey: String
    ) async throws -> CoachAboutMeQuestionsResult {
        let request: APIRequest<CoachAboutMeQuestionsResult> = try .delete(
            "/api/coach/about-me/questions",
            body: write,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await api.send(request)
    }

    // MARK: - Private

    private func enqueueAdopt(_ write: CoachAboutMeAdoptWrite, idempotencyKey: IdempotencyKey) async {
        guard let outbox else { return }
        do {
            let payload = try encoder.encode(OutboxQueue.Payloads.CoachAboutMeAdopt(write: write))
            try await outbox.enqueue(.init(
                kind: .coachAboutMeAdopt,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            ))
        } catch {
            HLLog.outbox.error("Outbox enqueue (coachAboutMeAdopt) failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }

    private func enqueueDismiss(_ write: CoachAboutMeDismissWrite, idempotencyKey: IdempotencyKey) async {
        guard let outbox else { return }
        do {
            let payload = try encoder.encode(OutboxQueue.Payloads.CoachAboutMeDismissQuestion(write: write))
            try await outbox.enqueue(.init(
                kind: .coachAboutMeDismissQuestion,
                payload: payload,
                idempotencyKey: idempotencyKey.raw
            ))
        } catch {
            HLLog.outbox.error(
                "Outbox enqueue (coachAboutMeDismissQuestion) failed: \(LogSanitizer.redact(String(describing: error)))"
            )
        }
    }
}
