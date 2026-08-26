import Foundation

/// Wraps the Coach conversation-history READ endpoints (server
/// `src/app/api/insights/chat/route.ts` GET + `.../chat/[id]/route.ts` GET):
///
/// - `GET /api/insights/chat?cursor=&limit=` → cursor-paginated rail list
///   (``CoachConversationsPageDTO``; metadata only, `updatedAt` desc).
/// - `GET /api/insights/chat/{id}`           → one conversation with every
///   message decrypted server-side (``CoachConversationDetailDTO``; messages
///   oldest-first).
///
/// **Coach kill-switch.** Both handlers are `requireAuth()` then
/// `await requireAssistantSurface("coach")`; a disabled surface 403s with
/// `errorCode: "assistant.disabled.coach"`, which ``APIClient`` maps to
/// ``HLError/assistantDisabled(.assistantCoach)``. Callers branch on that typed
/// error to render the calm disabled placeholder rather than a transport error —
/// identical to ``CoachFactsRepository``.
///
/// **Read + forget (#30, v1.18.0).** The read half (above) re-hydrates
/// server-retained conversations (including ones started on web) so the coach no
/// longer *looks* forgetful across relaunch/device. The *forget* half —
/// ``deleteConversation(id:)`` (`DELETE /api/insights/chat/{id}`, Bearer) — lets
/// the user drop a conversation server-side. This is the remaining piece of the
/// adopt/forget write-loop (POST send already lives in ``CoachServerService``).
///
/// **DELETE is user-initiated + online only.** No Outbox here: a forget is a
/// deliberate, foreground gesture, not an offline-tolerant optimistic write, and
/// the idempotency key on the request makes an in-request retry safe. Errors are
/// surfaced as typed ``HLError`` so the store can roll the row back. **Defensive
/// against a contract/deploy skew:** live may still be ≤ v1.17.1 where the route
/// is absent — a `404`/`405` surfaces as a plain ``HLError/server(status:_:_:)``
/// the caller treats gracefully (row stays, calm hint), never a crash.
public actor CoachConversationHistoryRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// List the caller's conversations for the rail. `cursor` is the id of the
    /// last row of the previous page (`nil` for the first page); `limit` defaults
    /// server-side (20, hard cap 50). Server order (`updatedAt` desc) preserved.
    /// Throws ``HLError/assistantDisabled(_:)`` when the Coach surface is disabled.
    public func list(cursor: String? = nil, limit: Int? = nil) async throws -> CoachConversationsPageDTO {
        var query: [(String, String)] = []
        if let cursor { query.append(("cursor", cursor)) }
        if let limit { query.append(("limit", String(limit))) }
        let req: APIRequest<CoachConversationsPageDTO> = .get("/api/insights/chat", query: query)
        return try await api.send(req)
    }

    /// Fetch one conversation with all its messages (decrypted server-side,
    /// oldest-first). A foreign / unknown id maps to **404** server-side — the
    /// transport surfaces it as ``HLError`` so the caller can show "not found"
    /// without leaking the cross-account existence channel.
    public func detail(id: String) async throws -> CoachConversationDetailDTO {
        let req: APIRequest<CoachConversationDetailDTO> = .get("/api/insights/chat/\(id)")
        return try await api.send(req)
    }

    /// Forget one conversation server-side (`DELETE /api/insights/chat/{id}`,
    /// Bearer). The server responds 2xx with an empty / `{}` body — decoded as
    /// ``EmptyResponse``. Carries an idempotency key (like every other mutation)
    /// so an in-request retry can't double-act.
    ///
    /// Throws ``HLError/assistantDisabled(_:)`` when the Coach surface is disabled
    /// and ``HLError/moduleDisabled(_:)`` when the whole module is off (both
    /// already mapped by ``APIClient``). A `404`/`405` — a foreign/unknown id, an
    /// already-deleted row, or a not-yet-deployed route (live ≤ v1.17.1) —
    /// surfaces as a plain ``HLError/server(status:_:_:)`` so the caller can keep
    /// the row and show a calm hint instead of crashing.
    public func deleteConversation(id: String) async throws {
        let req: APIRequest<EmptyResponse> = .delete("/api/insights/chat/\(id)")
        _ = try await api.send(req)
    }
}
