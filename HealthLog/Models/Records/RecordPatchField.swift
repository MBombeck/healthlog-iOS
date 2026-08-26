import Foundation

// Shared support types for the v1.25 structured-record surfaces (Allergies +
// Family history). These records' PATCH routes (`.strict()` on the server)
// distinguish THREE wire states for a clearable column — and a plain
// `encodeIfPresent` cannot express the difference between the last two:
//
//   - **omit the key**      → the column is left UNTOUCHED.
//   - **send `null`**       → the column is CLEARED.
//   - **send a value**      → the column is SET.
//
// The illness `Patch` structs never needed this (no nullable-clear field), so
// `RecordPatchField` is the new primitive that makes the distinction explicit
// (INV-B §6 caveat). Each `*Patch` struct in this folder hand-rolls `Codable`
// over these fields so an omitted field, an explicit clear, and a set value all
// round-trip exactly — which is what the outbox replay re-issues verbatim.

/// A tri-state edit field for a PATCH body: `unchanged` (omit the key on the
/// wire), `clear` (emit an explicit JSON `null`), or `set` (emit the value).
///
/// `Codable` round-trips perfectly: encoding emits nothing / `null` / the value,
/// and decoding maps absent → `unchanged`, present-`null` → `clear`, present
/// value → `set`. Conditionally `Sendable`/`Equatable` so the enclosing `*Patch`
/// stays `Sendable` (outbox payload) + `Equatable` (test assertions).
public enum RecordPatchField<Value> {
    /// Omit the key — the server leaves the column untouched.
    case unchanged
    /// Emit an explicit JSON `null` — the server clears the column.
    case clear
    /// Emit the value — the server sets the column.
    case set(Value)

    /// True when the field carries a concrete value (`set`).
    public var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    /// The wrapped value when `set`, else `nil` (does NOT distinguish
    /// `unchanged` from `clear`).
    public var value: Value? {
        if case let .set(v) = self { return v }
        return nil
    }
}

extension RecordPatchField: Sendable where Value: Sendable {}
extension RecordPatchField: Equatable where Value: Equatable {}
/// Conditionally `Hashable` so an enclosing `*Patch` that is itself `Hashable`
/// (e.g. `MedicationInventoryPatch`, stored in an outbox payload) keeps its
/// synthesized conformance after adopting a tri-state field.
extension RecordPatchField: Hashable where Value: Hashable {}

public extension RecordPatchField where Value: Encodable {
    /// Encode this field into `container` under `key`: omit on `unchanged`,
    /// `encodeNil` on `clear`, `encode` the value on `set`. Call from the
    /// enclosing `*Patch.encode(to:)`.
    func encode<K: CodingKey>(into container: inout KeyedEncodingContainer<K>, forKey key: K) throws {
        switch self {
        case .unchanged:
            break
        case .clear:
            try container.encodeNil(forKey: key)
        case let .set(value):
            try container.encode(value, forKey: key)
        }
    }
}

public extension RecordPatchField where Value: Decodable {
    /// Decode this field from `container` at `key`: absent → `unchanged`,
    /// present-`null` → `clear`, present value → `set`. The inverse of
    /// ``encode(into:forKey:)`` so a `*Patch` round-trips through the outbox.
    static func decode<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> RecordPatchField<Value> {
        guard container.contains(key) else { return .unchanged }
        if try container.decodeNil(forKey: key) { return .clear }
        return try .set(container.decode(Value.self, forKey: key))
    }
}

// MARK: - DeleteRecordResult

/// `DELETE /api/allergies/{id}` and `DELETE /api/family-history/{id}` both return
/// `200 { data: { deleted: true }, error: null }` (a soft-delete — re-deleting is
/// an idempotent no-op; there is NO restore endpoint). `APIClient.send` strips the
/// envelope and decodes this `data`-position object. Tolerant: a missing `deleted`
/// key (or a bare `{}` / transitional `204`) decodes to `false` rather than
/// crashing — mirrors ``DeleteIllnessEpisodeResult``.
public struct DeleteRecordResult: Decodable, Sendable, Equatable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        deleted = (try? c?.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case deleted
    }
}
