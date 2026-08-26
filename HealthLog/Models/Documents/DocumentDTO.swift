import Foundation

// Wire DTOs for the "Dokumente" document-vault surface — the server's
// `/api/documents/inbound*` contract (opt-in `inboundDocuments` module).
//
// Source of truth: `HealthLog/docs/api/openapi.yaml` →
//   `InboundDocument` / `InboundDocumentList(Envelope)` / `InboundDocumentDetail`
//   / `DocumentUsage` / `DocumentBulkResponse` / `ExtractedFact` / their envelopes.
//
// CONTRACT FACTS the client honours:
//   - **Opt-in module.** The whole surface gates on
//     `ModuleGate.isEnabled(.inboundDocuments)`; every route 403s with
//     `meta.errorCode: "module.disabled"` + `meta.module: "inboundDocuments"`
//     when the user (or operator) has the module off. `DocumentsRepository`
//     recognises that 403 (see ``DocumentsRepository/isModuleDisabled(_:)``).
//   - **STORE-only.** A freshly uploaded file is `status: STORED` with NO
//     extraction. AI extraction is a separate opt-in action (`/extract`).
//   - **`servingClass` decides delivery, not the MIME guess.** `inline`
//     (PDF/JPEG/PNG/WebP/GIF) renders inline; `attachment` (Office/text/TIFF/
//     HEIC/XML/JSON) is download-only.
//   - **Unknown `kind` → OTHER on decode** (explicit contract note).
//
// Every struct is `Sendable` + tolerant-decode (`decodeIfPresent` + safe
// defaults, String-backed enums with a `.unknown`/`.other` fallback) so a field
// added later — or an unknown enum member — never hard-fails the whole envelope
// (Illness / Labs DTO precedent). Calendar / instant date fields stay raw
// `String` (the wire is ISO-8601 / `YYYY-MM-DD`).

// MARK: - DocumentKind

/// `{ DOCTOR_REPORT | DISCHARGE_LETTER | LAB_RESULT | IMAGING | PRESCRIPTION |
/// REFERRAL | INSURANCE | VACCINATION | OTHER }` — the document category.
/// Tolerant decode: an unknown wire string falls back to ``other`` (explicit
/// contract note: "Treat an unknown `kind` value as OTHER when decoding").
public enum DocumentKind: String, Codable, Sendable, CaseIterable, Equatable, Identifiable, Hashable {
    case doctorReport = "DOCTOR_REPORT"
    case dischargeLetter = "DISCHARGE_LETTER"
    case labResult = "LAB_RESULT"
    case imaging = "IMAGING"
    case prescription = "PRESCRIPTION"
    case referral = "REFERRAL"
    case insurance = "INSURANCE"
    case vaccination = "VACCINATION"
    case other = "OTHER"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentKind(rawValue: raw) ?? .other
    }
}

// MARK: - DocumentStatus

/// `{ STORED | EXTRACTING | EXTRACTED | FAILED | CONFIRMED | DISCARDED }` — the
/// document lifecycle. `STORED` is a freshly uploaded file (no extraction run).
/// Tolerant decode falls back to ``stored`` for an unknown wire string.
public enum DocumentStatus: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case stored = "STORED"
    case extracting = "EXTRACTING"
    case extracted = "EXTRACTED"
    case failed = "FAILED"
    case confirmed = "CONFIRMED"
    case discarded = "DISCARDED"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentStatus(rawValue: raw) ?? .stored
    }
}

// MARK: - DocumentServingClass

/// `{ inline | attachment }` — how `/original` delivers the file. Render/download
/// by THIS, never by a MIME guess. Tolerant decode falls back to the SAFER
/// ``attachment`` (download-only) for an unknown wire string, so a future serving
/// class is never wrongly rendered inline in a sandbox-less viewer.
public enum DocumentServingClass: String, Codable, Sendable, Equatable, Hashable {
    case inline
    case attachment

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentServingClass(rawValue: raw) ?? .attachment
    }
}

// MARK: - DocumentContentIndexSource

/// `{ vision | text-ocr | local-pdf | local-ocr }` — HOW a document's content
/// index was produced (mirrors the web
/// `DOCUMENT_CONTENT_INDEX_SOURCES` / `isAiReadSource` in
/// `src/lib/validations/inbound-documents.ts`). `vision` means an AI provider
/// actually read the original; every other value is a provider-free local
/// extraction.
///
/// The server column is a free `String` (adding a source needs no migration), so
/// the decode is deliberately tolerant: an unrecognised wire string lands on
/// ``unknown`` instead of throwing — the provenance line then simply stays
/// hidden. A JSON `null` / an absent key decodes to `nil` via `decodeIfPresent`
/// and never reaches this initializer.
public enum DocumentContentIndexSource: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case vision
    case textOCR = "text-ocr"
    case localPDF = "local-pdf"
    case localOCR = "local-ocr"
    /// Any wire value this build does not know yet — never AI-read.
    case unknown

    /// True when the index was produced by an AI provider reading the original
    /// (the web's `isAiReadSource`). Only ``vision`` qualifies; a future/unknown
    /// source is conservatively NOT treated as an AI read.
    public var isAiReadSource: Bool {
        self == .vision
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentContentIndexSource(rawValue: raw) ?? .unknown
    }
}

// MARK: - DocumentConditionLink

/// A link to one of the caller's illness/condition episodes. `name` is the
/// episode's user-facing label.
public struct DocumentConditionLink: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let episodeId: String
    public let name: String

    public var id: String {
        episodeId
    }

    public init(episodeId: String, name: String) {
        self.episodeId = episodeId
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case episodeId, name
    }
}

// MARK: - InboundDocument

/// A stored document — the metadata + staging summary (the raw bytes stay
/// encrypted at rest and are never returned; fetch them via
/// ``DocumentsRepository/original(id:)``).
public struct InboundDocument: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let kind: DocumentKind
    public let title: String?
    public let filename: String?
    public let mimeType: String
    public let byteSize: Int
    public let status: DocumentStatus
    public let providerType: String?
    /// Model-transcribed report date (null until extraction runs).
    public let reportDate: String?
    /// User filing date (`YYYY-MM-DD`).
    public let documentDate: String?
    public let errorReason: String?
    public let factCount: Int
    public let pendingCount: Int
    public let conditionLinks: [DocumentConditionLink]
    public let servingClass: DocumentServingClass
    /// Vault Phase 2 (v1.27.22): `true` once the document body is in the blind
    /// content-search index (drives the detail "durchsuchbar" caption + the
    /// index-vs-reindex affordance). Older servers omit it → `false` (feature
    /// absent, never a crash).
    public let hasContentIndex: Bool
    /// How ``hasContentIndex`` was produced — `vision` (an AI provider read the
    /// original) vs a local extraction, `nil` when the document is not indexed
    /// or the server predates the field. Drives the "Von KI gelesen" provenance
    /// line only; never a to-do.
    public let contentIndexSource: DocumentContentIndexSource?
    /// The PERSISTED background AI summary — a short plain-language description
    /// of WHAT the document is, generated once after upload by the server's
    /// auto-read job. Descriptive only, never a diagnosis.
    ///
    /// Wire-wise this lives on the *detail* payload only
    /// (`InboundDocumentDetailDto`); the list omits it. It is modelled here (not
    /// on ``InboundDocumentDetail``) because the detail object FLATTENS the
    /// document fields alongside `facts`, so the same tolerant decode picks it
    /// up, and the detail screen keeps a single `InboundDocument` in state. On a
    /// list row it is simply `nil`.
    public let summary: String?
    /// ISO instant the persisted ``summary`` was generated (muted meta under the
    /// prose). `nil` when there is no summary.
    public let summaryGeneratedAt: String?
    public let createdAt: String
    public let updatedAt: String

    /// True when the content index came from an AI provider reading the original
    /// — the web's `hasContentIndex && isAiReadSource(contentIndexSource)`.
    public var isAiRead: Bool {
        hasContentIndex && (contentIndexSource?.isAiReadSource ?? false)
    }

    /// The persisted summary, trimmed, or `nil` when absent/blank — so a
    /// whitespace-only server value never paints an empty section.
    public var resolvedSummary: String? {
        guard let summary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The best display date: the user filing date if set, else the created
    /// timestamp. Used by the card + list sort headers.
    public var displayDate: String {
        if let documentDate, !documentDate.isEmpty { return documentDate }
        return createdAt
    }

    /// The best display title: the user label if set, else the filename, else
    /// `nil` (the card then paints a localized "Untitled" fallback).
    public var resolvedTitle: String? {
        if let title, !title.isEmpty { return title }
        if let filename, !filename.isEmpty { return filename }
        return nil
    }

    public init(
        id: String,
        kind: DocumentKind,
        title: String?,
        filename: String?,
        mimeType: String,
        byteSize: Int,
        status: DocumentStatus,
        providerType: String?,
        reportDate: String?,
        documentDate: String?,
        errorReason: String?,
        factCount: Int,
        pendingCount: Int,
        conditionLinks: [DocumentConditionLink],
        servingClass: DocumentServingClass,
        hasContentIndex: Bool = false,
        contentIndexSource: DocumentContentIndexSource? = nil,
        summary: String? = nil,
        summaryGeneratedAt: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.status = status
        self.providerType = providerType
        self.reportDate = reportDate
        self.documentDate = documentDate
        self.errorReason = errorReason
        self.factCount = factCount
        self.pendingCount = pendingCount
        self.conditionLinks = conditionLinks
        self.servingClass = servingClass
        self.hasContentIndex = hasContentIndex
        self.contentIndexSource = contentIndexSource
        self.summary = summary
        self.summaryGeneratedAt = summaryGeneratedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        byteSize = try Self.decodeFlexibleInt(c, forKey: .byteSize) ?? 0
        status = try c.decodeIfPresent(DocumentStatus.self, forKey: .status) ?? .stored
        providerType = try c.decodeIfPresent(String.self, forKey: .providerType)
        reportDate = try c.decodeIfPresent(String.self, forKey: .reportDate)
        documentDate = try c.decodeIfPresent(String.self, forKey: .documentDate)
        errorReason = try c.decodeIfPresent(String.self, forKey: .errorReason)
        factCount = try Self.decodeFlexibleInt(c, forKey: .factCount) ?? 0
        pendingCount = try Self.decodeFlexibleInt(c, forKey: .pendingCount) ?? 0
        conditionLinks = try c.decodeIfPresent([DocumentConditionLink].self, forKey: .conditionLinks) ?? []
        servingClass = try c.decodeIfPresent(DocumentServingClass.self, forKey: .servingClass) ?? .attachment
        hasContentIndex = try c.decodeIfPresent(Bool.self, forKey: .hasContentIndex) ?? false
        // Wave-4 parity fields. All three go through `decodeIfPresent` (the
        // source additionally through `decodeTolerantSource` below), so an
        // absent key, an explicit `null`, an unknown source literal AND a
        // wrong-typed value each degrade to `nil` / `.unknown` instead of
        // failing the whole list decode.
        contentIndexSource = Self.decodeTolerantSource(c)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryGeneratedAt = try c.decodeIfPresent(String.self, forKey: .summaryGeneratedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    /// Read `contentIndexSource` as a raw string first, then narrow it — the
    /// server column is a free `String`, so an unrecognised value becomes
    /// ``DocumentContentIndexSource/unknown`` and a wrong-typed / absent / null
    /// value becomes `nil`. Neither can fail the enclosing document decode.
    private static func decodeTolerantSource(_ c: KeyedDecodingContainer<CodingKeys>) -> DocumentContentIndexSource? {
        guard let raw = try? c.decodeIfPresent(String.self, forKey: .contentIndexSource), !raw.isEmpty else {
            return nil
        }
        return DocumentContentIndexSource(rawValue: raw) ?? .unknown
    }

    /// The wire sends numeric fields as JSON `number`; decode either an `Int` or
    /// a `Double` (or a numeric string) so a fractional/stringified byte size
    /// never fails the whole document decode.
    static func decodeFlexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, filename, mimeType, byteSize, status, providerType
        case reportDate, documentDate, errorReason, factCount, pendingCount
        case conditionLinks, servingClass, hasContentIndex, contentIndexSource
        case summary, summaryGeneratedAt, createdAt, updatedAt
    }
}

// MARK: - InboundDocumentList (list page)

/// A page of documents plus an opaque `nextCursor` (the value to pass back as
/// `cursor` for the next page; `nil` when the list is exhausted). `APIClient.send`
/// strips the outer `{ data, error }` envelope, so the repo decodes this
/// `data`-position object directly.
public struct InboundDocumentList: Decodable, Sendable, Equatable {
    public let documents: [InboundDocument]
    public let nextCursor: String?

    public init(documents: [InboundDocument], nextCursor: String?) {
        self.documents = documents
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documents = try c.decodeIfPresent([InboundDocument].self, forKey: .documents) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    private enum CodingKeys: String, CodingKey {
        case documents, nextCursor
    }
}

// MARK: - DocumentContentIndex (vault Phase 2 — content-search coverage)

/// Vault Phase 2 (v1.27.22): the caller's content-search index coverage.
/// `enabled` is true when the server can build the blind body index at all (a
/// vision provider is configured); `indexedCount` / `totalCount` back the
/// "Volltextsuche aktiv · N/M indexiert" caption + the backfill affordance.
/// Older servers omit the whole block → the feature is simply absent.
public struct DocumentContentIndex: Decodable, Sendable, Equatable {
    public let enabled: Bool
    public let indexedCount: Int
    public let totalCount: Int

    /// True when at least one document still lacks a content index — the
    /// "Jetzt indexieren" backfill is only worth offering then.
    public var hasUnindexed: Bool {
        totalCount > indexedCount
    }

    public init(enabled: Bool, indexedCount: Int, totalCount: Int) {
        self.enabled = enabled
        self.indexedCount = indexedCount
        self.totalCount = totalCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        indexedCount = try Self.flexInt(c, .indexedCount)
        totalCount = try Self.flexInt(c, .totalCount)
    }

    private static func flexInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return 0
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, indexedCount, totalCount
    }
}

// MARK: - DocumentUsage (quota + limits)

/// The caller's vault usage + effective limits. Read this BEFORE offering an
/// upload — `maxFileBytes` is the per-file cap, `quotaBytes − usedBytes` the
/// remaining headroom, `acceptedExtensions` the picker `accept` list, and
/// `linkedEpisodes` the condition-filter chips.
///
/// Vault Phase 2 (v1.27.22) adds ``assistAvailable`` (the server can serve the
/// AI-assist actions — one AND-half of the client gate; the other half is the
/// app's own AI consent) and ``contentIndex`` (content-search coverage). Both
/// are tolerant/optional — an older server omits them and the features stay
/// hidden with no crash.
public struct DocumentUsage: Decodable, Sendable, Equatable {
    public let usedBytes: Int
    public let quotaBytes: Int
    public let maxFileBytes: Int
    public let acceptedExtensions: [String]
    public let linkedEpisodes: [DocumentConditionLink]
    /// Phase 2: the server side of the assist gate (a document-scan provider is
    /// configured + the module/consent server checks pass). The client still
    /// ANDs this with its own AI-consent gate before offering any AI action.
    public let assistAvailable: Bool
    /// Phase 2: content-search index coverage, or `nil` on a pre-P2 server.
    public let contentIndex: DocumentContentIndex?

    /// Remaining headroom in bytes (never negative).
    public var remainingBytes: Int {
        max(0, quotaBytes - usedBytes)
    }

    /// Fraction of quota used, clamped to `0...1`. `0` when the quota is 0
    /// (defensive — avoids a divide-by-zero paint).
    public var usedFraction: Double {
        guard quotaBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(quotaBytes)))
    }

    public init(
        usedBytes: Int,
        quotaBytes: Int,
        maxFileBytes: Int,
        acceptedExtensions: [String],
        linkedEpisodes: [DocumentConditionLink],
        assistAvailable: Bool = false,
        contentIndex: DocumentContentIndex? = nil
    ) {
        self.usedBytes = usedBytes
        self.quotaBytes = quotaBytes
        self.maxFileBytes = maxFileBytes
        self.acceptedExtensions = acceptedExtensions
        self.linkedEpisodes = linkedEpisodes
        self.assistAvailable = assistAvailable
        self.contentIndex = contentIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedBytes = try Self.flexInt(c, .usedBytes)
        quotaBytes = try Self.flexInt(c, .quotaBytes)
        maxFileBytes = try Self.flexInt(c, .maxFileBytes)
        acceptedExtensions = try c.decodeIfPresent([String].self, forKey: .acceptedExtensions) ?? []
        linkedEpisodes = try c.decodeIfPresent([DocumentConditionLink].self, forKey: .linkedEpisodes) ?? []
        assistAvailable = try c.decodeIfPresent(Bool.self, forKey: .assistAvailable) ?? false
        contentIndex = try c.decodeIfPresent(DocumentContentIndex.self, forKey: .contentIndex)
    }

    private static func flexInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return 0
    }

    private enum CodingKeys: String, CodingKey {
        case usedBytes, quotaBytes, maxFileBytes, acceptedExtensions, linkedEpisodes
        case assistAvailable, contentIndex
    }
}

// MARK: - InboundDocumentDetail (document + staged facts)

/// A document PLUS its staged facts (the review payload). Shares every
/// ``InboundDocument`` field and adds ``facts``.
public struct InboundDocumentDetail: Decodable, Sendable, Equatable, Identifiable {
    public let document: InboundDocument
    public let facts: [ExtractedFact]

    public var id: String {
        document.id
    }

    /// The persisted background summary (wire-wise detail-only; decoded onto the
    /// flattened ``document`` — see ``InboundDocument/summary``).
    public var summary: String? {
        document.resolvedSummary
    }

    /// ISO instant the persisted ``summary`` was generated.
    public var summaryGeneratedAt: String? {
        document.summaryGeneratedAt
    }

    /// The web's `labFactCount`: staged OBSERVATION facts the user has not
    /// rejected. Drives the "N Laborwerte" jump on the detail screen.
    public var labFactCount: Int {
        InboundDocumentDetail.labFactCount(in: facts)
    }

    /// Pure counter so the screen can compute the same number from its own
    /// `facts` snapshot (and tests can pin it without a detail envelope).
    public static func labFactCount(in facts: [ExtractedFact]) -> Int {
        facts.filter { $0.factType == .observation && $0.status != .rejected }.count
    }

    public init(document: InboundDocument, facts: [ExtractedFact]) {
        self.document = document
        self.facts = facts
    }

    public init(from decoder: Decoder) throws {
        // The detail object flattens the document fields alongside `facts`, so
        // decode the document from the SAME container and pull `facts` out.
        document = try InboundDocument(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = try c.decodeIfPresent([ExtractedFact].self, forKey: .facts) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case facts
    }
}
