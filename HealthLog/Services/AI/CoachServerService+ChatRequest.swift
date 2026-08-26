import Foundation

/// Request body for `POST /api/insights/chat`. Mirrors `coachChatRequestSchema`
/// server-side (`src/lib/ai/coach/types.ts`). Split out of
/// `CoachServerService.swift` (A360, v0156) to keep that file under the 600-line
/// SwiftLint ceiling once the scope-handoff body landed.
///
/// **A360 H1 (v0156)** — `scope` is now sent. The server's v1.21.0 headline
/// coach feature ("Frag den Coach dazu") threads a `scope` ({ sources, window })
/// from insight-card / metric surfaces so the coach knows which metric the user
/// was looking at. iOS previously dropped it; we now attach it on the first turn
/// of a scoped conversation (the store decides when). `prefill` is the optional
/// first-turn nudge the server treats as informational only. Both are optional
/// and back-compat: an older server (v1.21.0 not yet on prod/demo) defaults the
/// missing fields and ignores an unrecognised key, so sending them is harmless.
struct ChatRequestBody: Encodable {
    let conversationId: String?
    let message: String
    let locale: String
    /// Wire `scope` ({ sources, window }) — `nil` for an unscoped turn.
    let scope: CoachScopeWire?
    /// First-turn composer-seed nudge — `nil` when the turn carries none.
    let prefill: String?

    init(
        conversationId: String?,
        message: String,
        locale: String,
        scope: CoachScopeWire? = nil,
        prefill: String? = nil
    ) {
        self.conversationId = conversationId
        self.message = message
        self.locale = locale
        self.scope = scope
        self.prefill = prefill
    }

    private enum CodingKeys: String, CodingKey {
        case conversationId
        case message
        case locale
        case scope
        case prefill
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encode(message, forKey: .message)
        try container.encode(locale, forKey: .locale)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encodeIfPresent(prefill, forKey: .prefill)
    }
}
