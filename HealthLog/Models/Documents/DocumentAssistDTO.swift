import Foundation

// Vault Phase 2 (server v1.27.22, iOS issue #43) — the additive AI-assist +
// content-search response DTOs for the document vault. All decode the `data`
// position (APIClient strips the `{ data, error }` envelope) and are tolerant:
// every field is optional/defaulted so an older server, or a forward-compatible
// field added later, never hard-fails the whole envelope.
//
// CONTRACT FACTS the client honours:
//   - **/suggest writes NOTHING.** It returns a `{ title, kind, documentDate }`
//     DRAFT that the detail sheet prefills into its editable fields; the user
//     reviews + saves. Never auto-committed.
//   - **/summary is SESSION-ONLY.** `?mode=summary` returns `{ summary }`,
//     `?mode=text` returns `{ text }`; nothing is persisted, and it is a
//     description — NOT a diagnosis (a discreet caveat is shown).
//   - **/index + /reindex** build the blind content-search index (idempotent;
//     re-indexing overwrites in place). Gated on the existing AI consent.
//   - Unknown `kind` on a suggestion decodes to `nil` (no forced OTHER) — a
//     suggestion with no readable kind simply offers no kind row.

// MARK: - DocumentSuggestion (filing-metadata draft)

/// The `{ title, kind, documentDate }` DRAFT from
/// `POST /api/documents/inbound/{id}/suggest`. Every field is nullable — the
/// provider offers only what it could read. These are drafts the user applies
/// explicitly (title seeds the editable field; kind/date commit one field each
/// through the existing edit-on-commit path) — nothing here is written by the
/// suggest call itself.
public struct DocumentSuggestion: Decodable, Sendable, Equatable {
    public let title: String?
    /// The suggested category, or `nil` when none was read or the wire value is
    /// an unknown enum member (a suggestion, unlike a stored document, is not
    /// coerced to `.other` — an unreadable kind simply offers no kind row).
    public let kind: DocumentKind?
    /// Suggested filing date (`YYYY-MM-DD`), or `nil`.
    public let documentDate: String?

    /// True when the provider read at least one fileable field — drives the
    /// "nothing to suggest" empty copy vs. the review rows.
    public var hasAny: Bool {
        (title?.isEmpty == false) || kind != nil || (documentDate?.isEmpty == false)
    }

    public init(title: String?, kind: DocumentKind?, documentDate: String?) {
        self.title = title
        self.kind = kind
        self.documentDate = documentDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        if let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) {
            kind = DocumentKind(rawValue: rawKind)
        } else {
            kind = nil
        }
        documentDate = try c.decodeIfPresent(String.self, forKey: .documentDate)
    }

    private enum CodingKeys: String, CodingKey {
        case title, kind, documentDate
    }
}

/// The `data` object of the suggest response: `{ suggestions: { … } }`.
public struct DocumentSuggestResponse: Decodable, Sendable, Equatable {
    public let suggestions: DocumentSuggestion

    public init(suggestions: DocumentSuggestion) {
        self.suggestions = suggestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestions = try c.decodeIfPresent(DocumentSuggestion.self, forKey: .suggestions)
            ?? DocumentSuggestion(title: nil, kind: nil, documentDate: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case suggestions
    }
}

// MARK: - DocumentSummary (session-only description)

/// The `data` object of `POST /api/documents/inbound/{id}/summary` — a
/// session-only `{ summary }` (mode=summary) XOR `{ text }` (mode=text). Both
/// fields are optional; ``prose`` resolves whichever the server returned. The
/// result is transient (never persisted) and descriptive only — NOT a diagnosis.
public struct DocumentSummary: Decodable, Sendable, Equatable {
    public let summary: String?
    public let text: String?

    /// The renderable prose — the summary if present, else the raw text.
    public var prose: String? {
        if let summary, !summary.isEmpty { return summary }
        if let text, !text.isEmpty { return text }
        return nil
    }

    public init(summary: String?, text: String?) {
        self.summary = summary
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey {
        case summary, text
    }
}

/// `?mode=` selector for the summary route — a plain-language description
/// (`summary`, default) or the raw transcribed text (`text`).
public enum DocumentSummaryMode: String, Sendable, Equatable {
    case summary
    case text
}

// MARK: - DocumentIndexResult (per-document content index)

/// The `data` object of `POST /api/documents/inbound/{id}/index` —
/// `{ documentId, indexed, tokenCount }`. `indexed` reports whether the body is
/// now searchable; `tokenCount` is the blind-token cardinality.
public struct DocumentIndexResult: Decodable, Sendable, Equatable {
    public let documentId: String
    public let indexed: Bool
    public let tokenCount: Int

    public init(documentId: String, indexed: Bool, tokenCount: Int) {
        self.documentId = documentId
        self.indexed = indexed
        self.tokenCount = tokenCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentId = try c.decodeIfPresent(String.self, forKey: .documentId) ?? ""
        indexed = try c.decodeIfPresent(Bool.self, forKey: .indexed) ?? false
        if let i = try? c.decodeIfPresent(Int.self, forKey: .tokenCount) {
            tokenCount = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .tokenCount) {
            tokenCount = Int(d)
        } else {
            tokenCount = 0
        }
    }

    private enum CodingKeys: String, CodingKey {
        case documentId, indexed, tokenCount
    }
}

// MARK: - DocumentReindexResult (corpus backfill)

/// The `data` object of `POST /api/documents/inbound/reindex` — `{ enqueued }`.
/// The server enqueues a bounded, resumable backfill of not-yet-indexed
/// documents and returns immediately. `enqueued` decodes tolerantly from either
/// a `Bool` or a `number` (the web wire types it as a count; the OpenAPI as a
/// boolean) — any positive/true value reads as "a job was enqueued".
public struct DocumentReindexResult: Decodable, Sendable, Equatable {
    public let enqueued: Bool

    public init(enqueued: Bool) {
        self.enqueued = enqueued
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .enqueued) {
            enqueued = b
        } else if let n = try? c.decodeIfPresent(Double.self, forKey: .enqueued) {
            enqueued = n > 0
        } else {
            enqueued = false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enqueued
    }
}

// MARK: - DocumentAiTextRequest (opt-in on-device OCR body)

/// The optional TEXT-mode body shared by `/suggest`, `/summary`, and `/index`
/// (`{ mode: "text", text, kind? }`). VISION mode sends no body (see the
/// repository). This mirrors ``DocumentTextExtractRequest`` but is kept distinct
/// so the assist routes can evolve independently of `/extract`.
public struct DocumentAiTextRequest: Encodable, Sendable, Equatable {
    public let mode: String
    public let text: String
    public let kind: DocumentKind?

    public init(text: String, kind: DocumentKind? = nil) {
        mode = "text"
        self.text = text
        self.kind = kind
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(kind?.rawValue, forKey: .kind)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, text, kind
    }
}
