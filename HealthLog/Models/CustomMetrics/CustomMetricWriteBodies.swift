import Foundation

// Wire WRITE bodies for the custom-metric store. Split out of
// `CustomMetricDTO.swift` under the PROJECT_GUIDE.md `file_length` discipline, mirroring
// the `LabsDTO` / `LabsWriteBodies` split.
//
// The two PATCH routes are the interesting half. Both servers build their Prisma
// `data` object FIELD-BY-FIELD and distinguish three wire states
// (`[id]/route.ts:113-119`, `[id]/entries/[entryId]/route.ts:73-76`):
//
//   - omit the key  → column UNTOUCHED
//   - explicit null → column CLEARED
//   - a value       → column SET
//
// A plain `encodeIfPresent` collapses the last two, which would make a target
// bound / description / note IMPOSSIBLE to clear once set — the labs `Patch`
// structs accepted exactly that limitation ("models clears as omissions for
// now"), and the web custom-metric form does support clearing. So the patch
// bodies below use the existing ``RecordPatchField`` tri-state primitive.

// MARK: - Metric definition

/// `POST /api/custom-metrics` body. `name` + `unit` required (both trimmed,
/// 1...120 / 1...40 server-side); the rest optional.
///
/// A `409` means a LIVE metric already owns this name. Note the server also
/// REVIVES a soft-deleted metric of the same name instead of 409-ing
/// (`route.ts:100-135`) — so a create can legitimately return a metric that
/// already has `entryCount > 0`. The store must not assume a fresh definition
/// is empty.
public struct CustomMetricCreate: Codable, Sendable, Equatable {
    public var name: String
    public var unit: String
    public var targetLow: Double?
    public var targetHigh: Double?
    public var decimals: Int?
    public var description: String?
    /// **CU-35 (3)** — whether this metric may take part in the correlation
    /// analysis (`createCustomMetricSchema`: `z.boolean().default(false)`).
    ///
    /// This is a **consent to being analysed**, not a display option: switching
    /// it on lets the server compare this metric's values against other health
    /// data looking for associations. Default `false` matches the server's, so a
    /// metric only ever joins the analysis because someone said so.
    public var correlationEnabled: Bool

    public init(
        name: String,
        unit: String,
        targetLow: Double? = nil,
        targetHigh: Double? = nil,
        decimals: Int? = nil,
        description: String? = nil,
        correlationEnabled: Bool = false
    ) {
        self.name = name
        self.unit = unit
        self.targetLow = targetLow
        self.targetHigh = targetHigh
        self.decimals = decimals
        self.description = description
        self.correlationEnabled = correlationEnabled
    }

    /// Emit only the keys that are set. The create schema has no nullable-clear
    /// arm (`z.number().optional()`, no `.or(z.null())`) — sending an explicit
    /// `null` for a bound would be a 422, so absent MUST mean absent here.
    ///
    /// `correlationEnabled` is the exception and is ALWAYS emitted: it is a
    /// boolean with a server-side default, and stating it explicitly means the
    /// stored value can never disagree with the switch the user just looked at.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(targetLow, forKey: .targetLow)
        try c.encodeIfPresent(targetHigh, forKey: .targetHigh)
        try c.encodeIfPresent(decimals, forKey: .decimals)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(correlationEnabled, forKey: .correlationEnabled)
    }

    /// Declared explicitly: a type that provides BOTH `encode(to:)` and
    /// `init(from:)` gets no synthesised `CodingKeys` (see `CustomMetricPatch`).
    private enum CodingKeys: String, CodingKey {
        case name, unit, targetLow, targetHigh, decimals, description, correlationEnabled
    }

    /// Custom decode for ONE reason: an Outbox row queued by a build before
    /// CU-35 carries no `correlationEnabled` key, and a synthesised decode of a
    /// non-optional `Bool` would throw on it — turning a queued create into a
    /// replay that can never drain. Absent reads as `false`, the same answer the
    /// server's own default gives.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        unit = try c.decode(String.self, forKey: .unit)
        targetLow = try c.decodeIfPresent(Double.self, forKey: .targetLow)
        targetHigh = try c.decodeIfPresent(Double.self, forKey: .targetHigh)
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        correlationEnabled = try c.decodeIfPresent(Bool.self, forKey: .correlationEnabled) ?? false
    }
}

/// `PATCH /api/custom-metrics/{id}` partial edit.
///
/// `name` / `unit` are plain optionals (the schema has no null arm for them —
/// they are `requiredText(...).optional()`), while the four clearable columns
/// use ``RecordPatchField`` so "leave alone" and "clear" stay distinguishable.
public struct CustomMetricPatch: Codable, Sendable, Equatable {
    public var name: String?
    public var unit: String?
    public var targetLow: RecordPatchField<Double>
    public var targetHigh: RecordPatchField<Double>
    public var decimals: RecordPatchField<Int>
    public var description: RecordPatchField<String>
    /// **CU-35 (3)** — the correlation-analysis consent. `z.boolean().optional()`
    /// on `updateCustomMetricSchema` with **no null arm**, so it is a plain
    /// optional (omit = leave alone) rather than a ``RecordPatchField``: there is
    /// no third "clear it" state for a boolean the server always stores.
    public var correlationEnabled: Bool?

    public init(
        name: String? = nil,
        unit: String? = nil,
        targetLow: RecordPatchField<Double> = .unchanged,
        targetHigh: RecordPatchField<Double> = .unchanged,
        decimals: RecordPatchField<Int> = .unchanged,
        description: RecordPatchField<String> = .unchanged,
        correlationEnabled: Bool? = nil
    ) {
        self.name = name
        self.unit = unit
        self.targetLow = targetLow
        self.targetHigh = targetHigh
        self.decimals = decimals
        self.description = description
        self.correlationEnabled = correlationEnabled
    }

    /// Convenience for the editor sheet: build a full-surface patch from the
    /// edited values, mapping `nil` on a clearable field to an explicit CLEAR.
    /// The editor always presents every field, so "the user emptied the target
    /// low box" genuinely means clear — not "leave whatever was there".
    public static func fullEdit(
        name: String,
        unit: String,
        targetLow: Double?,
        targetHigh: Double?,
        decimals: Int?,
        description: String?,
        correlationEnabled: Bool
    ) -> CustomMetricPatch {
        CustomMetricPatch(
            name: name,
            unit: unit,
            targetLow: targetLow.map { .set($0) } ?? .clear,
            targetHigh: targetHigh.map { .set($0) } ?? .clear,
            decimals: decimals.map { .set($0) } ?? .clear,
            description: description.map { .set($0) } ?? .clear,
            correlationEnabled: correlationEnabled
        )
    }

    /// Declared explicitly: a type that provides BOTH `encode(to:)` and
    /// `init(from:)` gets no synthesised `CodingKeys`.
    private enum CodingKeys: String, CodingKey {
        case name, unit, targetLow, targetHigh, decimals, description, correlationEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(unit, forKey: .unit)
        try targetLow.encode(into: &c, forKey: .targetLow)
        try targetHigh.encode(into: &c, forKey: .targetHigh)
        try decimals.encode(into: &c, forKey: .decimals)
        try description.encode(into: &c, forKey: .description)
        try c.encodeIfPresent(correlationEnabled, forKey: .correlationEnabled)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        targetLow = try RecordPatchField<Double>.decode(from: c, forKey: .targetLow)
        targetHigh = try RecordPatchField<Double>.decode(from: c, forKey: .targetHigh)
        decimals = try RecordPatchField<Int>.decode(from: c, forKey: .decimals)
        description = try RecordPatchField<String>.decode(from: c, forKey: .description)
        correlationEnabled = try c.decodeIfPresent(Bool.self, forKey: .correlationEnabled)
    }
}

// MARK: - Logged value

/// `POST /api/custom-metrics/{id}/entries` body. All three keys map 1:1 to
/// `createCustomMetricEntrySchema`; the metric's `unit` is NOT sent — the server
/// snapshots its own current unit onto the row.
public struct CustomMetricEntryCreate: Codable, Sendable, Equatable {
    public var value: Double
    /// ISO-8601. Server-bounded: not in the future, not older than 50 years
    /// (`ENTRY_MAX_AGE_MS`), and above the shared 1900 floor.
    public var measuredAt: String
    public var note: String?

    public init(value: Double, measuredAt: String, note: String? = nil) {
        self.value = value
        self.measuredAt = measuredAt
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(measuredAt, forKey: .measuredAt)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// `PATCH /api/custom-metrics/{id}/entries/{entryId}` partial edit. `note` is
/// the one clearable column (the schema gives it — and only it — a `.or(z.null())`
/// arm); `value` / `measuredAt` are set-or-omit.
public struct CustomMetricEntryPatch: Codable, Sendable, Equatable {
    public var value: Double?
    public var measuredAt: String?
    public var note: RecordPatchField<String>

    public init(
        value: Double? = nil,
        measuredAt: String? = nil,
        note: RecordPatchField<String> = .unchanged
    ) {
        self.value = value
        self.measuredAt = measuredAt
        self.note = note
    }

    /// Convenience for the edit sheet, which always presents all three fields:
    /// an emptied note box is a genuine CLEAR.
    public static func fullEdit(value: Double, measuredAt: String, note: String?) -> CustomMetricEntryPatch {
        CustomMetricEntryPatch(
            value: value,
            measuredAt: measuredAt,
            note: note.map { .set($0) } ?? .clear
        )
    }

    /// Declared explicitly: see `CustomMetricPatch.CodingKeys`.
    private enum CodingKeys: String, CodingKey {
        case value, measuredAt, note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try note.encode(into: &c, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        measuredAt = try c.decodeIfPresent(String.self, forKey: .measuredAt)
        note = try RecordPatchField<String>.decode(from: c, forKey: .note)
    }
}
