import Foundation

// The staged-fact half of the documents contract (`ExtractedFact`) plus a small
// tolerant JSON value used for the fact's free-form `data` payload.
//
// Extraction is the OPTIONAL AI enhancement (`POST /api/documents/inbound/{id}/
// extract`) — a store-only upload never produces facts. The client models facts
// for tolerant decode + a read-only review summary; the per-fact edit/confirm
// write path mirrors a large web review flow and is intentionally out of the
// first iOS cut (see the module report). Facts are STATED only — never
// interpreted.

// MARK: - HLJSONValue

/// A minimal, tolerant JSON value for schemaless payloads (the fact `data`
/// object, whose shape varies by `factType`). Decodes any JSON scalar / array /
/// object without failing, so an unforeseen field never breaks the fact decode.
public enum HLJSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HLJSONValue])
    case array([HLJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([HLJSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: HLJSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .number(n): try c.encode(n)
        case let .bool(b): try c.encode(b)
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// A human-readable rendering for a scalar (used by the read-only fact
    /// summary). Objects/arrays render empty (the summary shows scalars only).
    public var displayString: String? {
        switch self {
        case let .string(s):
            s
        case let .number(n):
            if n == n.rounded() { String(Int(n)) } else { String(describing: n) }
        case let .bool(b):
            b ? "true" : "false"
        case .object, .array, .null:
            nil
        }
    }
}

// MARK: - ExtractedFactType

/// `{ CONDITION | OBSERVATION | MEDICATION_STATEMENT }` — the staged fact's FHIR
/// resource class. Tolerant decode falls back to ``observation``.
public enum ExtractedFactType: String, Codable, Sendable, Equatable, Hashable {
    case condition = "CONDITION"
    case observation = "OBSERVATION"
    case medicationStatement = "MEDICATION_STATEMENT"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExtractedFactType(rawValue: raw) ?? .observation
    }
}

// MARK: - ExtractedFactStatus

/// `{ PENDING | APPROVED | REJECTED }` — the staged fact's review status.
/// Tolerant decode falls back to ``pending``.
public enum ExtractedFactStatus: String, Codable, Sendable, Equatable, Hashable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExtractedFactStatus(rawValue: raw) ?? .pending
    }
}

// MARK: - ExtractedFactProvenance

/// Per-field provenance for a staged fact: the verbatim `sourceText`, an optional
/// `page`, and the model `confidence`.
public struct ExtractedFactProvenance: Codable, Sendable, Equatable, Hashable {
    public let sourceText: String
    public let page: Int?
    public let confidence: Double

    public init(sourceText: String, page: Int?, confidence: Double) {
        self.sourceText = sourceText
        self.page = page
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case sourceText, page, confidence
    }
}

// MARK: - ExtractedFact

/// One STATED fact transcribed from a document, FHIR-staged with per-field
/// provenance + a confidence gate. `needsReview` is true when the fact scored
/// below the confidence floor (it cannot be approved until edited).
public struct ExtractedFact: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let factType: ExtractedFactType
    public let status: ExtractedFactStatus
    public let confidence: Double
    public let needsReview: Bool
    public let data: [String: HLJSONValue]
    public let provenance: ExtractedFactProvenance?
    public let committedRecordId: String?
    public let committedRecordType: String?

    /// The best single-line label for the fact summary: the `label`/`name` field
    /// out of `data` when present, else the raw source text.
    public var summaryLabel: String? {
        if let label = data["label"]?.displayString, !label.isEmpty { return label }
        if let name = data["name"]?.displayString, !name.isEmpty { return name }
        if let text = provenance?.sourceText, !text.isEmpty { return text }
        return nil
    }

    public init(
        id: String,
        factType: ExtractedFactType,
        status: ExtractedFactStatus,
        confidence: Double,
        needsReview: Bool,
        data: [String: HLJSONValue],
        provenance: ExtractedFactProvenance?,
        committedRecordId: String?,
        committedRecordType: String?
    ) {
        self.id = id
        self.factType = factType
        self.status = status
        self.confidence = confidence
        self.needsReview = needsReview
        self.data = data
        self.provenance = provenance
        self.committedRecordId = committedRecordId
        self.committedRecordType = committedRecordType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        factType = try c.decodeIfPresent(ExtractedFactType.self, forKey: .factType) ?? .observation
        status = try c.decodeIfPresent(ExtractedFactStatus.self, forKey: .status) ?? .pending
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        data = try c.decodeIfPresent([String: HLJSONValue].self, forKey: .data) ?? [:]
        provenance = try c.decodeIfPresent(ExtractedFactProvenance.self, forKey: .provenance)
        committedRecordId = try c.decodeIfPresent(String.self, forKey: .committedRecordId)
        committedRecordType = try c.decodeIfPresent(String.self, forKey: .committedRecordType)
    }

    private enum CodingKeys: String, CodingKey {
        case id, factType, status, confidence, needsReview, data, provenance
        case committedRecordId, committedRecordType
    }
}
