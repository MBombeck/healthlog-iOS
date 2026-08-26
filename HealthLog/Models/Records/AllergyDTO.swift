import Foundation

// Wire DTOs for the v1.25 structured-records ALLERGY surface (FHIR
// `AllergyIntolerance`; server `W-RECORDS`).
//
// Source of truth (verified 2026-06-28 against the `HealthLog` server repo
// `release/v1.25.0`):
//   - `src/lib/validations/allergy.ts` (enums + create/update/list schemas)
//   - `src/lib/records/dto.ts` → `AllergyDTO` / `toAllergyDTO`
//   - `src/app/api/allergies/route.ts` (+ `[id]/route.ts`)
//
// CONTRACT FACTS the client must honour:
//   - A structured RECORD (reference data), not a time-series signal. `substance`
//     is the deliberately-plaintext, queryable human label (the FHIR `code.text`
//     anchor) — NEVER a machine-guessed code.
//   - `reaction` + `note` are DECRYPTED free-text PHI (server decrypts fail-soft;
//     a key-rotation gap reads `null`, never a 500). iOS MUST treat them as PHI:
//     clear on logout, never log.
//   - Mutations are **PATCH, not PUT**; the clearable fields (`severity`,
//     `onsetAt`, `reaction`, `note`) need tri-state encoding — see ``AllergyPatch``.
//   - DELETE is a **soft, idempotent** delete (`200 { deleted: true }`); there is
//     NO restore endpoint.
//
// Every struct is `Sendable` + tolerant-decode (`decodeIfPresent` + safe
// defaults, unknown enum members fall back) so a future field or unknown enum
// never hard-fails the whole envelope (CycleDTO / IllnessDTO precedent). Instant
// fields stay raw `String` (the wire is ISO-8601).

// MARK: - AllergyCategory

/// `{ FOOD | MEDICATION | ENVIRONMENT | BIOLOGIC | OTHER }` (server default
/// `OTHER`). Tolerant decode → ``other``.
public enum AllergyCategory: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case food = "FOOD"
    case medication = "MEDICATION"
    case environment = "ENVIRONMENT"
    case biologic = "BIOLOGIC"
    case other = "OTHER"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AllergyCategory(rawValue: raw) ?? .other
    }
}

// MARK: - AllergyType

/// `{ ALLERGY | INTOLERANCE }` (server default `ALLERGY`). Tolerant → ``allergy``.
public enum AllergyType: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case allergy = "ALLERGY"
    case intolerance = "INTOLERANCE"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AllergyType(rawValue: raw) ?? .allergy
    }
}

// MARK: - AllergySeverity

/// `{ MILD | MODERATE | SEVERE }` — optional/nullable on the wire (no default).
/// Tolerant decode → ``mild`` for an unknown member (only reached when a value is
/// present; the field itself stays optional on the DTO).
public enum AllergySeverity: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case mild = "MILD"
    case moderate = "MODERATE"
    case severe = "SEVERE"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AllergySeverity(rawValue: raw) ?? .mild
    }
}

// MARK: - AllergyStatus

/// `{ ACTIVE | INACTIVE | RESOLVED }` (server default `ACTIVE`). Tolerant →
/// ``active``.
public enum AllergyStatus: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case active = "ACTIVE"
    case inactive = "INACTIVE"
    case resolved = "RESOLVED"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AllergyStatus(rawValue: raw) ?? .active
    }
}

// MARK: - AllergyDTO

/// One stored allergy / intolerance record (`AllergyDTO`). `reaction` + `note`
/// are the decrypted free-text PHI (or `nil` on a key-rotation gap — fail-soft,
/// never an error). `severity` / `onsetAt` are `nil` when unknown.
public struct AllergyDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// Queryable human label (FHIR `code.text` anchor) — plaintext.
    public let substance: String
    public let category: AllergyCategory
    public let type: AllergyType
    public let severity: AllergySeverity?
    public let status: AllergyStatus
    /// `YYYY-MM-DDTHH:mm:ssZ` or `nil` when the onset is unknown.
    public let onsetAt: String?
    /// Decrypted free-text reaction description (PHI) or `nil`.
    public let reaction: String?
    /// Decrypted free-text note (PHI) or `nil`.
    public let note: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        substance: String,
        category: AllergyCategory,
        type: AllergyType,
        severity: AllergySeverity?,
        status: AllergyStatus,
        onsetAt: String?,
        reaction: String?,
        note: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.substance = substance
        self.category = category
        self.type = type
        self.severity = severity
        self.status = status
        self.onsetAt = onsetAt
        self.reaction = reaction
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        substance = try c.decodeIfPresent(String.self, forKey: .substance) ?? ""
        category = try c.decodeIfPresent(AllergyCategory.self, forKey: .category) ?? .other
        type = try c.decodeIfPresent(AllergyType.self, forKey: .type) ?? .allergy
        severity = try c.decodeIfPresent(AllergySeverity.self, forKey: .severity)
        status = try c.decodeIfPresent(AllergyStatus.self, forKey: .status) ?? .active
        onsetAt = try c.decodeIfPresent(String.self, forKey: .onsetAt)
        reaction = try c.decodeIfPresent(String.self, forKey: .reaction)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - Write bodies

/// `POST /api/allergies`. `substance` is always emitted (required, 1–160 chars);
/// the rest are emitted only when set so the server applies its defaults
/// (`category=OTHER`, `type=ALLERGY`, `status=ACTIVE`). `reaction` / `note` are
/// encrypted at rest server-side.
public struct AllergyCreate: Codable, Sendable, Equatable {
    public var substance: String
    public var category: AllergyCategory?
    public var type: AllergyType?
    public var severity: AllergySeverity?
    public var status: AllergyStatus?
    public var onsetAt: String?
    public var reaction: String?
    public var note: String?

    public init(
        substance: String,
        category: AllergyCategory? = nil,
        type: AllergyType? = nil,
        severity: AllergySeverity? = nil,
        status: AllergyStatus? = nil,
        onsetAt: String? = nil,
        reaction: String? = nil,
        note: String? = nil
    ) {
        self.substance = substance
        self.category = category
        self.type = type
        self.severity = severity
        self.status = status
        self.onsetAt = onsetAt
        self.reaction = reaction
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(substance, forKey: .substance)
        try c.encodeIfPresent(category?.rawValue, forKey: .category)
        try c.encodeIfPresent(type?.rawValue, forKey: .type)
        try c.encodeIfPresent(severity?.rawValue, forKey: .severity)
        try c.encodeIfPresent(status?.rawValue, forKey: .status)
        try c.encodeIfPresent(onsetAt, forKey: .onsetAt)
        try c.encodeIfPresent(reaction, forKey: .reaction)
        try c.encodeIfPresent(note, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case substance, category, type, severity, status, onsetAt, reaction, note
    }
}

/// `PATCH /api/allergies/{id}` partial edit. The server schema is `.strict()`:
/// an omitted key is untouched, an explicit `null` clears the column. The
/// clearable columns (`severity`, `onsetAt`, `reaction`, `note`) therefore use
/// ``RecordPatchField`` (tri-state). `substance` / `category` / `type` / `status`
/// are non-nullable on update, so they only ever take `.unchanged` / `.set`
/// (never `.clear`).
public struct AllergyPatch: Codable, Sendable, Equatable {
    public var substance: RecordPatchField<String>
    public var category: RecordPatchField<AllergyCategory>
    public var type: RecordPatchField<AllergyType>
    public var severity: RecordPatchField<AllergySeverity>
    public var status: RecordPatchField<AllergyStatus>
    public var onsetAt: RecordPatchField<String>
    public var reaction: RecordPatchField<String>
    public var note: RecordPatchField<String>

    public init(
        substance: RecordPatchField<String> = .unchanged,
        category: RecordPatchField<AllergyCategory> = .unchanged,
        type: RecordPatchField<AllergyType> = .unchanged,
        severity: RecordPatchField<AllergySeverity> = .unchanged,
        status: RecordPatchField<AllergyStatus> = .unchanged,
        onsetAt: RecordPatchField<String> = .unchanged,
        reaction: RecordPatchField<String> = .unchanged,
        note: RecordPatchField<String> = .unchanged
    ) {
        self.substance = substance
        self.category = category
        self.type = type
        self.severity = severity
        self.status = status
        self.onsetAt = onsetAt
        self.reaction = reaction
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try substance.encode(into: &c, forKey: .substance)
        try category.encode(into: &c, forKey: .category)
        try type.encode(into: &c, forKey: .type)
        try severity.encode(into: &c, forKey: .severity)
        try status.encode(into: &c, forKey: .status)
        try onsetAt.encode(into: &c, forKey: .onsetAt)
        try reaction.encode(into: &c, forKey: .reaction)
        try note.encode(into: &c, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        substance = try .decode(from: c, forKey: .substance)
        category = try .decode(from: c, forKey: .category)
        type = try .decode(from: c, forKey: .type)
        severity = try .decode(from: c, forKey: .severity)
        status = try .decode(from: c, forKey: .status)
        onsetAt = try .decode(from: c, forKey: .onsetAt)
        reaction = try .decode(from: c, forKey: .reaction)
        note = try .decode(from: c, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case substance, category, type, severity, status, onsetAt, reaction, note
    }
}
