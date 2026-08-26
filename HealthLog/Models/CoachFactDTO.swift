import Foundation

// Coach memory ("what the assistant knows") DTOs — server v1.12.1 B4
// (`src/app/api/insights/coach/facts/route.ts`, `.../facts/[id]/route.ts`).
//
// A coach fact is a server-EXTRACTED snippet the assistant has learned about the
// user (e.g. "prefers metric units", "trains in the morning"). They are not
// user-authored, so the surface is **read + delete only** (no POST/PATCH):
//   - `GET    /api/insights/coach/facts`      → list ACTIVE facts.
//   - `DELETE /api/insights/coach/facts/{id}` → soft-delete one (idempotent).
//   - `DELETE /api/insights/coach/facts`      → soft-delete all ("forget all").
//
// **Auth + gate (B4):** every handler is `requireAuth()` (cookie OR Bearer) then
// `await requireAssistantSurface("coach")`. If the operator disabled the Coach
// surface the gate throws `403 + errorCode: "assistant.disabled.coach"`, which
// `APIClient` already maps to ``HLError/assistantDisabled(.assistantCoach)`` — the
// same kill-switch the rest of the Coach stack honours. No new client gate needed.

// MARK: - CoachFactDTO (server row projection)

/// One coach fact. `confidence` is the server's 0…1 extraction confidence;
/// `createdAt` is an ISO-8601 string. The list arrives ordered confidence desc
/// then createdAt desc — we preserve that server order.
public struct CoachFactDTO: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let category: String
    public let text: String
    public let confidence: Double
    public let createdAt: String

    public init(id: String, category: String, text: String, confidence: Double, createdAt: String) {
        self.id = id
        self.category = category
        self.text = text
        self.confidence = confidence
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, text, confidence, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        text = try c.decode(String.self, forKey: .text)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

// MARK: - List response

/// `GET /api/insights/coach/facts` → `data.facts[]` (active only).
public struct CoachFactsListResponse: Decodable, Sendable {
    public let facts: [CoachFactDTO]

    public init(facts: [CoachFactDTO]) {
        self.facts = facts
    }

    private enum CodingKeys: String, CodingKey {
        case facts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = try c.decodeIfPresent([CoachFactDTO].self, forKey: .facts) ?? []
    }
}

// MARK: - Delete responses

/// `DELETE /api/insights/coach/facts/{id}` → `{ data: { deleted: Bool } }`.
/// Idempotent: unknown / cross-user / already-deleted id → `{ deleted: false }`
/// (NO 404 — the existence channel never leaks).
public struct CoachFactDeleteResponse: Decodable, Sendable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// `DELETE /api/insights/coach/facts` ("forget all") → `{ data: { cleared: Int } }`.
public struct CoachFactsClearResponse: Decodable, Sendable {
    public let cleared: Int

    public init(cleared: Int) {
        self.cleared = cleared
    }

    private enum CodingKeys: String, CodingKey {
        case cleared
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cleared = try c.decodeIfPresent(Int.self, forKey: .cleared) ?? 0
    }
}
