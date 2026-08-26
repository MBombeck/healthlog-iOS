import Foundation

// Coach conversation-history DTOs — server `src/lib/ai/coach/types.ts`
// (`CoachConversationDTO` / `CoachMessageDTO` / `CoachConversationDetailDTO`)
// surfaced by the read endpoints:
//
//   - `GET /api/insights/chat`        → `data.{ conversations[], nextCursor }`
//     (cursor-paginated rail list; metadata only, no decrypted bodies).
//   - `GET /api/insights/chat/{id}`   → `data.{ …conversation, messages[], summary }`
//     (one conversation with every message decrypted server-side).
//
// **Auth + gate.** Both handlers are `requireAuth()` (cookie OR Bearer) then
// `await requireAssistantSurface("coach")`. A disabled Coach surface throws
// `403 + errorCode: "assistant.disabled.coach"`, which ``APIClient`` already maps
// to ``HLError/assistantDisabled(.assistantCoach)`` — the same kill-switch the
// rest of the Coach stack honours. A foreign / unknown id maps to **404** on the
// detail route (the existence channel never leaks across accounts).
//
// **Read-only (b182).** iOS chat is local-first; these DTOs back a *re-hydration*
// read path so server-retained conversations (and ones started on web) are
// browsable on iOS again — the adopt/forget write-loop stays a follow-up.

// MARK: - CoachConversationSummaryDTO (rail list row)

/// One conversation in the rail list. Metadata only — the server defers body
/// decryption to the detail route, so there are no `messages` here. Ordered
/// `updatedAt` desc by the server; we preserve that order.
public struct CoachConversationSummaryDTO: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let updatedAt: String
    public let messageCount: Int

    public init(id: String, title: String, createdAt: String, updatedAt: String, messageCount: Int) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messageCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
    }
}

// MARK: - List response (cursor-paginated page)

/// `GET /api/insights/chat` → `data.{ conversations[], nextCursor }`. `nextCursor`
/// is the id of the last conversation on the page, or `nil` at the end.
public struct CoachConversationsPageDTO: Decodable, Sendable {
    public let conversations: [CoachConversationSummaryDTO]
    public let nextCursor: String?

    public init(conversations: [CoachConversationSummaryDTO], nextCursor: String?) {
        self.conversations = conversations
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case conversations, nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([CoachConversationSummaryDTO].self, forKey: .conversations) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - One message inside a conversation detail

/// One persisted turn, decrypted server-side. `role` is constrained to
/// `user`/`assistant` at the application layer server-side; an unrecognised value
/// folds to `.assistant` (schema-forward) so a future role can't crash the decode.
public struct CoachConversationMessageDTO: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let role: CoachChatRole
    public let content: String
    public let createdAt: String

    public init(id: String, role: CoachChatRole, content: String, createdAt: String) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let roleRaw = try c.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        role = CoachChatRole(rawValue: roleRaw) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

// MARK: - Detail response (one conversation, messages oldest-first)

/// `GET /api/insights/chat/{id}` → `data.{ id, title, …, messages[], summary }`.
/// `messages` arrive oldest-first (server `orderBy createdAt asc`) — the order we
/// need to re-hydrate a transcript top-to-bottom.
public struct CoachConversationDetailDTO: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let updatedAt: String
    public let messageCount: Int
    public let messages: [CoachConversationMessageDTO]
    /// Decrypted rolling summary of the elided older turns, or `nil` when none is
    /// on file. Surfaced read-only so the user can see what the coach folded away.
    public let summary: String?

    public init(
        id: String,
        title: String,
        createdAt: String,
        updatedAt: String,
        messageCount: Int,
        messages: [CoachConversationMessageDTO],
        summary: String?
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.messages = messages
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messageCount, messages, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        messages = try c.decodeIfPresent([CoachConversationMessageDTO].self, forKey: .messages) ?? []
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? messages.count
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}
