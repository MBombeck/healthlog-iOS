import Foundation

// Wire WRITE bodies for the labs + biomarker-catalog surface. Split out of
// `LabsDTO.swift` under the PROJECT_GUIDE.md file-length discipline when Build 1 /
// item 1.5 added the `valueText` arm; pure move, same contracts.
//
// Read DTOs (`LabResultDTO`, `LabResultDetailDTO`, `BiomarkerDTO`) and the list
// envelopes stay in `LabsDTO.swift`.

// MARK: - Write bodies

/// `POST /api/labs` body. `takenAt` plus EITHER `value` (numeric) OR `valueText`
/// (qualitative) required; the rest optional. When `biomarkerId` is set the
/// server resolves analyte/unit/range — the client still MAY send analyte/unit
/// for an unlinked row.
///
/// Item 1.5 — mirrors `lab-form.tsx:173-199`, which posts exactly one of
/// `{ value }` / `{ valueText }` and never both.
public struct LabResultCreate: Codable, Sendable, Equatable {
    public var biomarkerId: String?
    public var panel: String?
    public var analyte: String?
    public var value: Double?
    /// Qualitative result text ("negativ" / …). Set INSTEAD of ``value``.
    public var valueText: String?
    public var unit: String?
    public var referenceLow: Double?
    public var referenceHigh: Double?
    public var takenAt: String
    public var note: String?
    /// Provenance marker (#36 / server v1.25 — `POST /api/labs` accepts an
    /// optional `source ∈ {"MANUAL","OCR"}`). Set to `"OCR"` only for rows
    /// ingested through the on-device lab-photo scan + review path; left `nil`
    /// for hand-entered rows, which the server reads as `MANUAL`.
    public var source: String?

    public init(
        biomarkerId: String? = nil,
        panel: String? = nil,
        analyte: String? = nil,
        value: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        referenceLow: Double? = nil,
        referenceHigh: Double? = nil,
        takenAt: String,
        note: String? = nil,
        source: String? = nil
    ) {
        self.biomarkerId = biomarkerId
        self.panel = panel
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.takenAt = takenAt
        self.note = note
        self.source = source
    }

    /// Only emit keys that are set so an omitted field is "untouched" (the PUT
    /// route treats an explicit `null` as "clear", which create never wants).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(biomarkerId, forKey: .biomarkerId)
        try c.encodeIfPresent(panel, forKey: .panel)
        try c.encodeIfPresent(analyte, forKey: .analyte)
        // Exactly one of value / valueText is emitted (whichever the form set).
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(valueText, forKey: .valueText)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(referenceLow, forKey: .referenceLow)
        try c.encodeIfPresent(referenceHigh, forKey: .referenceHigh)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

/// `PUT /api/labs/{id}` partial edit. Every field optional; an omitted field is
/// untouched.
///
/// **Build 3 / item 3.2 — clearable fields are now TRI-STATE.** The server's
/// `updateLabResultSchema` (`src/lib/validations/labs.ts:154-168`) accepts an
/// explicit `null` on `panel` / `note` / `referenceLow` / `referenceHigh` to
/// CLEAR the column, distinct from an omitted key that leaves it untouched. The
/// old `String?` + `encodeIfPresent` shape could not express the difference: a
/// user who emptied the note field sent NOTHING, the server left the row
/// untouched, and the note came back on the next sync. The audit flagged
/// exactly this (§A3 "Notiz löschen können"); Build 1 fixed the same class for
/// illness notes.
///
/// These four fields use ``RecordPatchField`` — the primitive introduced for
/// the v1.25 record PATCH routes — so `unchanged` / `clear` / `set` all
/// round-trip verbatim through the outbox replay.
///
/// `analyte` / `unit` / `takenAt` stay plain optionals: the server schema does
/// NOT accept `null` for them (they are `requiredText(...).optional()`), so
/// there is no clear state to express. `value` / `valueText` likewise — the
/// server refuses type switches on PUT, so an omitted key is the only correct
/// way to leave the other arm alone.
public struct LabResultPatch: Codable, Sendable, Equatable {
    /// Clearable — send `.clear` to drop the row out of its panel grouping.
    public var panel: RecordPatchField<String>
    public var analyte: String?
    public var value: Double?
    /// Item 1.5 — qualitative result text. Sent INSTEAD of ``value`` when the
    /// editor is in qualitative mode.
    public var valueText: String?
    public var unit: String?
    /// Clearable — send `.clear` to remove a free-text row's lower bound.
    public var referenceLow: RecordPatchField<Double>
    /// Clearable — send `.clear` to remove a free-text row's upper bound.
    public var referenceHigh: RecordPatchField<Double>
    public var takenAt: String?
    /// Clearable — send `.clear` to delete the note. This is the field the
    /// audit caught: emptying it used to be a silent no-op.
    public var note: RecordPatchField<String>

    public init(
        panel: RecordPatchField<String> = .unchanged,
        analyte: String? = nil,
        value: Double? = nil,
        valueText: String? = nil,
        unit: String? = nil,
        referenceLow: RecordPatchField<Double> = .unchanged,
        referenceHigh: RecordPatchField<Double> = .unchanged,
        takenAt: String? = nil,
        note: RecordPatchField<String> = .unchanged
    ) {
        self.panel = panel
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.takenAt = takenAt
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panel = try RecordPatchField.decode(from: c, forKey: .panel)
        analyte = try c.decodeIfPresent(String.self, forKey: .analyte)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        valueText = try c.decodeIfPresent(String.self, forKey: .valueText)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        referenceLow = try RecordPatchField.decode(from: c, forKey: .referenceLow)
        referenceHigh = try RecordPatchField.decode(from: c, forKey: .referenceHigh)
        takenAt = try c.decodeIfPresent(String.self, forKey: .takenAt)
        note = try RecordPatchField.decode(from: c, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try panel.encode(into: &c, forKey: .panel)
        try c.encodeIfPresent(analyte, forKey: .analyte)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(valueText, forKey: .valueText)
        try c.encodeIfPresent(unit, forKey: .unit)
        try referenceLow.encode(into: &c, forKey: .referenceLow)
        try referenceHigh.encode(into: &c, forKey: .referenceHigh)
        try c.encodeIfPresent(takenAt, forKey: .takenAt)
        try note.encode(into: &c, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey {
        case panel, analyte, value, valueText, unit
        case referenceLow, referenceHigh, takenAt, note
    }
}

public extension RecordPatchField where Value == String {
    /// Build 3 / item 3.2 — the editor idiom for a clearable TEXT field: a
    /// blank (or whitespace-only) field means CLEAR, anything else means SET.
    ///
    /// Every clearable-text editor should route through this rather than
    /// hand-rolling the ternary, because the hand-rolled version is exactly
    /// what produced the bug: `text.isEmpty ? nil : text` collapses "clear" and
    /// "untouched" into the same `nil`.
    static func fromEditor(_ text: String) -> RecordPatchField<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .clear : .set(trimmed)
    }
}

public extension RecordPatchField where Value == Double {
    /// Build 3 / item 3.2 — the editor idiom for a clearable NUMERIC bound: a
    /// blank field means CLEAR, a parseable number means SET.
    ///
    /// A non-empty but UNPARSEABLE field ("abc") returns `.unchanged`: the user
    /// clearly intended a value, so silently clearing the stored bound would
    /// destroy data on a typo. Leaving it alone is the conservative reading.
    static func fromEditor(_ text: String, parse: (String) -> Double?) -> RecordPatchField<Double> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .clear }
        guard let value = parse(trimmed) else { return .unchanged }
        return .set(value)
    }
}

/// `POST /api/biomarkers` body. `name` + `unit` required.
public struct BiomarkerCreate: Codable, Sendable, Equatable {
    public var name: String
    public var unit: String
    public var lowerBound: Double?
    public var upperBound: Double?
    public var context: String?
    public var panel: String?

    public init(
        name: String,
        unit: String,
        lowerBound: Double? = nil,
        upperBound: Double? = nil,
        context: String? = nil,
        panel: String? = nil
    ) {
        self.name = name
        self.unit = unit
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.context = context
        self.panel = panel
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(lowerBound, forKey: .lowerBound)
        try c.encodeIfPresent(upperBound, forKey: .upperBound)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encodeIfPresent(panel, forKey: .panel)
    }
}

/// `PUT /api/biomarkers/{id}` partial edit. Omitted fields untouched.
///
/// **Build 3 / item 3.2 — same tri-state treatment as ``LabResultPatch``.**
/// `updateBiomarkerSchema` (`src/lib/validations/biomarkers.ts:65-88`) accepts
/// explicit `null` on `lowerBound` / `upperBound` / `context` / `panel` to
/// clear them; the old plain-optional shape could only overwrite, never remove.
/// A user who deleted a marker's upper bound saw it come back on the next sync.
///
/// `hidden` is a plain `Bool?` — the server takes `true` / `false` / omitted;
/// there is no null state.
public struct BiomarkerPatch: Codable, Sendable, Equatable {
    public var name: String?
    public var unit: String?
    /// Clearable — `.clear` removes the marker's lower reference bound.
    public var lowerBound: RecordPatchField<Double>
    /// Clearable — `.clear` removes the marker's upper reference bound.
    public var upperBound: RecordPatchField<Double>
    /// Clearable — `.clear` deletes the per-marker context note.
    public var context: RecordPatchField<String>
    /// Clearable — `.clear` drops the marker out of its panel grouping.
    public var panel: RecordPatchField<String>
    /// Build 3 / item 3.2 — hide / unhide (server `hidden`, v1.22). An omitted
    /// key leaves visibility untouched; `true` drops the marker from the active
    /// catalog list + every lab-entry picker WITHOUT deleting its readings.
    public var hidden: Bool?

    public init(
        name: String? = nil,
        unit: String? = nil,
        lowerBound: RecordPatchField<Double> = .unchanged,
        upperBound: RecordPatchField<Double> = .unchanged,
        context: RecordPatchField<String> = .unchanged,
        panel: RecordPatchField<String> = .unchanged,
        hidden: Bool? = nil
    ) {
        self.name = name
        self.unit = unit
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.context = context
        self.panel = panel
        self.hidden = hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        lowerBound = try RecordPatchField.decode(from: c, forKey: .lowerBound)
        upperBound = try RecordPatchField.decode(from: c, forKey: .upperBound)
        context = try RecordPatchField.decode(from: c, forKey: .context)
        panel = try RecordPatchField.decode(from: c, forKey: .panel)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(unit, forKey: .unit)
        try lowerBound.encode(into: &c, forKey: .lowerBound)
        try upperBound.encode(into: &c, forKey: .upperBound)
        try context.encode(into: &c, forKey: .context)
        try panel.encode(into: &c, forKey: .panel)
        try c.encodeIfPresent(hidden, forKey: .hidden)
    }

    private enum CodingKeys: String, CodingKey {
        case name, unit, lowerBound, upperBound, context, panel, hidden
    }
}

// MARK: - Reading display (item 1.5)

/// The ONE way a lab reading renders across list row, biomarker card and detail
/// header, so a qualitative row can never read as an empty measurement on one
/// surface and as "0" on another.
///
/// Precedence: numeric value (+ unit) → qualitative text (no unit; a qualitative
/// result has no dimension) → em-dash for a genuinely absent reading. The
/// em-dash is a typographic placeholder, not UI copy, and matches the existing
/// `MetricKindDescriptor` empty-value convention.
public enum LabValueDisplay {
    public static let absentPlaceholder = "—"

    public static func text(value: Double?, valueText: String?, unit: String) -> String {
        if let value {
            let formatted = value.formatted(.number.precision(.fractionLength(0 ... 2)))
            return unit.isEmpty ? formatted : "\(formatted) \(unit)"
        }
        if let valueText, !valueText.isEmpty {
            return valueText
        }
        return absentPlaceholder
    }
}

public extension LabResultDTO {
    /// Rendered reading — numeric + unit, qualitative text, or an em-dash.
    var displayValue: String {
        LabValueDisplay.text(value: value, valueText: valueText, unit: unit)
    }
}

public extension LabResultDetailDTO {
    /// Rendered reading — numeric + unit, qualitative text, or an em-dash.
    var displayValue: String {
        LabValueDisplay.text(value: value, valueText: valueText, unit: unit)
    }
}

/// `POST /api/labs/restore` body `{ ids: [String] }` (1..200).
public struct RestoreLabResultsRequest: Codable, Sendable, Equatable {
    public let ids: [String]

    public init(ids: [String]) {
        self.ids = ids
    }
}
