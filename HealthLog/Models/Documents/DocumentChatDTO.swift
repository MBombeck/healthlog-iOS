import Foundation

// Vault Phase 4 — document chat (server v1.27.33, iOS issue #43). The per-document
// Q&A wire types: the POST request body, the GET history shapes (a thread's
// messages XOR the document's thread list), and the SSE stream token the client
// surfaces. All decode the `data` position (APIClient strips the `{ data, error }`
// envelope) and are tolerant — every field is optional/defaulted so an older
// server, or a forward-compatible field added later, never hard-fails the whole
// envelope.
//
// CONTRACT FACTS the client honours:
//   - Chat is available ONLY for a content-indexed document — its indexed text is
//     the grounding (422 `documents.inbound.notIndexed` otherwise). The UI gates
//     on `hasContentIndex` and points at the index action when it's off.
//   - The reply is grounded ONLY in THIS document's own figures — NO health
//     snapshot, NO other document, NO diagnosis. A discreet caveat is always shown.
//   - The stream is `text/event-stream`: one `data: <json>\n\n` frame per event,
//     `type` ∈ { `token`, `done`, `error` }. HTTP is 200 even for a
//     provider/budget failure — dispatch on the `error` frame, never a status.

// MARK: - Request

/// Body for `POST /api/documents/inbound/{id}/chat`. `conversationId` continues an
/// existing thread (omitted → the server opens a new one); `locale` renders the
/// server's refusal / limit copy in the right language.
public struct DocumentChatRequest: Encodable, Sendable, Equatable {
    public let conversationId: String?
    public let message: String
    public let locale: String?

    public init(message: String, conversationId: String? = nil, locale: String? = nil) {
        self.message = message
        self.conversationId = conversationId
        self.locale = locale
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(message, forKey: .message)
        // Omit nils so a first turn carries no conversationId and an unset locale
        // leaves the server to fall back to its own default.
        try c.encodeIfPresent(conversationId, forKey: .conversationId)
        try c.encodeIfPresent(locale, forKey: .locale)
    }

    private enum CodingKeys: String, CodingKey {
        case conversationId, message, locale
    }
}

// MARK: - Roles + messages

/// Author of a document-chat turn. Tolerant — an unknown wire value reads as
/// `.assistant` (a forward role never drops the row).
public enum DocumentChatMessageRole: String, Decodable, Sendable, Equatable {
    case user
    case assistant

    init(wire: String?) {
        self = DocumentChatMessageRole(rawValue: wire ?? "") ?? .assistant
    }
}

/// One persisted turn of a document chat (the reused `CoachMessage` shape scoped
/// to a document). Only the fields the panel renders are decoded — `id`, `role`,
/// `content`, `createdAt`; the provider/token/model tails on the wire are ignored.
public struct DocumentChatMessageDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: DocumentChatMessageRole
    public let content: String
    public let createdAt: String

    public init(id: String, role: DocumentChatMessageRole, content: String, createdAt: String) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try DocumentChatMessageRole(wire: c.decodeIfPresent(String.self, forKey: .role))
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt
    }
}

// MARK: - History (thread detail XOR thread list)

/// One thread's decrypted messages (`GET …/chat?conversationId=…`). Oldest-first.
public struct DocumentChatDetail: Decodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let messages: [DocumentChatMessageDTO]

    public init(id: String, title: String, messages: [DocumentChatMessageDTO]) {
        self.id = id
        self.title = title
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        messages = try c.decodeIfPresent([DocumentChatMessageDTO].self, forKey: .messages) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages
    }
}

/// A summary row in the document's thread list (`GET …/chat` without an id).
public struct DocumentChatConversation: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let updatedAt: String
    public let messageCount: Int

    public init(id: String, title: String, updatedAt: String, messageCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        if let i = try? c.decodeIfPresent(Int.self, forKey: .messageCount) {
            messageCount = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .messageCount) {
            messageCount = Int(d)
        } else {
            messageCount = 0
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, updatedAt, messageCount
    }
}

/// The document's chat threads, newest-first (`GET …/chat` without a
/// conversationId). The panel keeps ONE active thread, so it takes the first.
public struct DocumentChatList: Decodable, Sendable, Equatable {
    public let conversations: [DocumentChatConversation]

    public init(conversations: [DocumentChatConversation]) {
        self.conversations = conversations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([DocumentChatConversation].self, forKey: .conversations) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case conversations
    }
}

/// The `anyOf` history response — a thread's messages (has `messages`) XOR the
/// document's thread list (has `conversations`). Decoded by which key is present.
public enum DocumentChatHistory: Decodable, Sendable, Equatable {
    case detail(DocumentChatDetail)
    case list(DocumentChatList)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A thread detail carries `messages`; the list carries `conversations`.
        // Prefer detail when `messages` is present (a conversationId query).
        if c.contains(.messages) {
            self = try .detail(DocumentChatDetail(from: decoder))
        } else {
            self = try .list(DocumentChatList(from: decoder))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case messages, conversations
    }

    /// The document's thread summaries — empty for a detail payload.
    public var conversations: [DocumentChatConversation] {
        if case let .list(list) = self { return list.conversations }
        return []
    }

    /// The resolved thread detail, or `nil` for a list payload.
    public var detail: DocumentChatDetail? {
        if case let .detail(detail) = self { return detail }
        return nil
    }
}

// MARK: - Stream token

/// One frame surfaced from the chat SSE stream. `token` grows the reply; `done`
/// closes the turn with the (new-or-existing) conversation id + persisted message
/// id. An `error` frame is NOT yielded — it maps to a thrown ``DocumentChatError``.
public enum DocumentChatStreamToken: Sendable, Equatable {
    case token(String)
    case done(conversationId: String?, messageId: String?)
}

// MARK: - Errors

/// Typed failure surface for the document-chat stream. The gate discriminators
/// (`notIndexed` / `consentRequired`) also arrive as `HLError.server` before the
/// stream opens (the repository maps them here); `limitReached` covers both the
/// transport 429 and the SSE budget-exhaustion `error` frame.
public enum DocumentChatError: Error, Sendable, Equatable {
    /// `422 documents.inbound.notIndexed` — the document has no content index yet.
    case notIndexed
    /// `403 consent.ai.required` — an external provider needs document-egress
    /// consent (the same receipt the capability route reports).
    case consentRequired
    /// Per-user rate bucket / budget exhausted — the SSE `error` frame or a 429.
    case limitReached
    /// The server emitted an `error` frame with another code (provider failure).
    case provider(String)
    /// The stream closed with no usable assistant text.
    case emptyReply
    /// The SSE body could not be parsed (non-UTF8 / no frames).
    case decode(String)
}
