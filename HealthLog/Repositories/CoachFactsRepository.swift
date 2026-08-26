import Foundation

/// Wraps the coach-memory ("what the assistant knows") endpoints (server v1.12.1
/// B4 — `src/app/api/insights/coach/facts/route.ts` + `[id]/route.ts`). All three
/// are Bearer-auth (no scope) **and** coach-gated via `requireAssistantSurface("coach")`:
///
/// - `GET    /api/insights/coach/facts`      → list ACTIVE facts (ordered by the
///   server: confidence desc, then createdAt desc — we preserve that order).
/// - `DELETE /api/insights/coach/facts/{id}` → soft-delete one. **Idempotent**:
///   unknown / cross-user / already-deleted id → `{ deleted: false }` (no 404).
/// - `DELETE /api/insights/coach/facts`      → soft-delete all ("forget all"),
///   returns `{ cleared: <count> }`.
///
/// **Coach kill-switch (B4).** If the operator disabled the Coach surface every
/// handler 403s with `errorCode: "assistant.disabled.coach"`. ``APIClient`` already
/// maps that pair to ``HLError/assistantDisabled(.assistantCoach)`` and mirrors the
/// flag into `FeatureFlagsStore` — so this repository surfaces the **same** typed
/// error the rest of the Coach stack handles. Callers branch on it to render the
/// calm disabled-surface placeholder rather than a transport error.
///
/// **Read + delete only.** Facts are server-extracted, not user-authored, so there
/// is deliberately no create/update path (matches a "what the assistant knows /
/// forget" screen).
public actor CoachFactsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// List the caller's active coach facts. Server order (confidence desc, then
    /// createdAt desc) is preserved. Throws ``HLError/assistantDisabled(_:)`` when
    /// the Coach surface is disabled.
    public func list() async throws -> [CoachFactDTO] {
        let req: APIRequest<CoachFactsListResponse> = .get("/api/insights/coach/facts")
        return try await api.send(req).facts
    }

    /// Forget one fact. Returns the server's `deleted` flag — `false` for an
    /// unknown / cross-user / already-deleted id (idempotent; the server never
    /// 404s on the existence channel). DELETE carries no idempotency header
    /// requirement, but the route is naturally idempotent.
    @discardableResult
    public func forget(id: String) async throws -> Bool {
        let req: APIRequest<CoachFactDeleteResponse> = .delete("/api/insights/coach/facts/\(id)")
        return try await api.send(req).deleted
    }

    /// Forget every active fact for the caller. Returns the count cleared.
    @discardableResult
    public func forgetAll() async throws -> Int {
        let req: APIRequest<CoachFactsClearResponse> = .delete("/api/insights/coach/facts")
        return try await api.send(req).cleared
    }
}
