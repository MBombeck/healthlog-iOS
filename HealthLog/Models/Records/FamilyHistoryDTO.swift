import Foundation

// Wire DTOs for the v1.25 structured-records FAMILY-HISTORY surface (FHIR
// `FamilyMemberHistory`; server `W-RECORDS`).
//
// Source of truth (verified 2026-06-28 against `release/v1.25.0`):
//   - `src/lib/validations/family-history.ts` (relationship enum + schemas)
//   - `src/lib/records/dto.ts` → `FamilyHistoryEntryDTO` / `toFamilyHistoryEntryDTO`
//   - `src/app/api/family-history/route.ts` (+ `[id]/route.ts`)
//
// CONTRACT FACTS: one condition per relative; `relationship` + `condition` are
// required on create (`condition` is the plaintext FHIR `code.text` label).
// `ageAtOnset` is an optional 0–120 int (null = unknown). `note` is decrypted
// free-text PHI (fail-soft null). PATCH (not PUT); `ageAtOnset` / `note` are
// tri-state-clearable. DELETE is soft + idempotent; no restore endpoint.

// MARK: - FamilyRelationship

/// The 15-value `relationship` enum (required on create). Tolerant decode → ``other``.
public enum FamilyRelationship: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case mother = "MOTHER"
    case father = "FATHER"
    case sister = "SISTER"
    case brother = "BROTHER"
    case daughter = "DAUGHTER"
    case son = "SON"
    case grandmotherMaternal = "GRANDMOTHER_MATERNAL"
    case grandfatherMaternal = "GRANDFATHER_MATERNAL"
    case grandmotherPaternal = "GRANDMOTHER_PATERNAL"
    case grandfatherPaternal = "GRANDFATHER_PATERNAL"
    case aunt = "AUNT"
    case uncle = "UNCLE"
    case cousin = "COUSIN"
    case halfSibling = "HALF_SIBLING"
    case other = "OTHER"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FamilyRelationship(rawValue: raw) ?? .other
    }
}

// MARK: - FamilyHistoryEntryDTO

/// One stored family-history entry (`FamilyHistoryEntryDTO`). `note` is decrypted
/// free-text PHI (or `nil` on a key-rotation gap). `ageAtOnset` is `nil` when the
/// relative's age at onset is unknown.
public struct FamilyHistoryEntryDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let relationship: FamilyRelationship
    /// User-facing condition label (FHIR `code.text` anchor) — plaintext.
    public let condition: String
    /// Relative's age (years) at onset, 0–120, or `nil` when unknown.
    public let ageAtOnset: Int?
    /// Decrypted free-text note (PHI) or `nil`.
    public let note: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        relationship: FamilyRelationship,
        condition: String,
        ageAtOnset: Int?,
        note: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.relationship = relationship
        self.condition = condition
        self.ageAtOnset = ageAtOnset
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        relationship = try c.decodeIfPresent(FamilyRelationship.self, forKey: .relationship) ?? .other
        condition = try c.decodeIfPresent(String.self, forKey: .condition) ?? ""
        ageAtOnset = try c.decodeIfPresent(Int.self, forKey: .ageAtOnset)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - Write bodies

/// `POST /api/family-history`. `relationship` + `condition` required; `ageAtOnset`
/// / `note` optional (note encrypted at rest server-side).
public struct FamilyHistoryCreate: Codable, Sendable, Equatable {
    public var relationship: FamilyRelationship
    public var condition: String
    public var ageAtOnset: Int?
    public var note: String?

    public init(
        relationship: FamilyRelationship,
        condition: String,
        ageAtOnset: Int? = nil,
        note: String? = nil
    ) {
        self.relationship = relationship
        self.condition = condition
        self.ageAtOnset = ageAtOnset
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(relationship.rawValue, forKey: .relationship)
        try c.encode(condition, forKey: .condition)
        try c.encodeIfPresent(ageAtOnset, forKey: .ageAtOnset)
        try c.encodeIfPresent(note, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case relationship, condition, ageAtOnset, note
    }
}

/// `PATCH /api/family-history/{id}` partial edit (`.strict()`). `relationship` /
/// `condition` are non-nullable on update (`.unchanged` / `.set` only); the
/// clearable `ageAtOnset` / `note` use ``RecordPatchField`` tri-state.
public struct FamilyHistoryPatch: Codable, Sendable, Equatable {
    public var relationship: RecordPatchField<FamilyRelationship>
    public var condition: RecordPatchField<String>
    public var ageAtOnset: RecordPatchField<Int>
    public var note: RecordPatchField<String>

    public init(
        relationship: RecordPatchField<FamilyRelationship> = .unchanged,
        condition: RecordPatchField<String> = .unchanged,
        ageAtOnset: RecordPatchField<Int> = .unchanged,
        note: RecordPatchField<String> = .unchanged
    ) {
        self.relationship = relationship
        self.condition = condition
        self.ageAtOnset = ageAtOnset
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try relationship.encode(into: &c, forKey: .relationship)
        try condition.encode(into: &c, forKey: .condition)
        try ageAtOnset.encode(into: &c, forKey: .ageAtOnset)
        try note.encode(into: &c, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relationship = try .decode(from: c, forKey: .relationship)
        condition = try .decode(from: c, forKey: .condition)
        ageAtOnset = try .decode(from: c, forKey: .ageAtOnset)
        note = try .decode(from: c, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case relationship, condition, ageAtOnset, note
    }
}
