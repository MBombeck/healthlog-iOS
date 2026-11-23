import Foundation

// Wire DTOs for the v1.18.1 labs + biomarker-catalog surface (server `W-LABS`).
//
// Source of truth (verified 2026-06-17 against `HealthLog` server repo):
//   - `docs/api/openapi.yaml` → `LabResult` / `LabResultDetail` /
//     `LabReferenceRangeStatus` / `Biomarker` + the list/create/restore
//     envelopes (`ListLabResultsResponse` carries `{ results, meta }`,
//     `ListBiomarkersResponse` carries `{ biomarkers }`).
//   - `.planning/ios-coord/v1.18.1-server-to-ios-contract.md` §1.
//
// CONTRACT FACTS the client must honour:
//   - `biomarkerId` is additive + nullable. When set, the server RESOLVES
//     `analyte` / `unit` / `referenceLow` / `referenceHigh` from the linked
//     `Biomarker`. The client RENDERS those resolved fields and NEVER recomputes
//     the range. Free-text (unlinked) rows keep their own fields.
//   - `rangeStatus` is the singular server-computed NEUTRAL verdict. It must
//     render calm/informative — NEVER an alarming red for `below`/`above`. The
//     typed accessor maps every status to a NON-critical `HLBadge.Tone`.
//
// Every struct is `Sendable` + `Codable` with **tolerant decode**
// (`decodeIfPresent` + safe defaults) so a field added later — or an unknown
// enum member — never hard-fails the whole envelope (CycleDTO precedent).
// Calendar-style date fields stay raw `String` (the wire is ISO-8601 / day key);
// only audit timestamps decode as `Date` where convenient.

// MARK: - LabReferenceRangeStatus

/// `{ in-range | below | above | unknown }` — the server-computed NEUTRAL
/// reference-range verdict (`LabReferenceRangeStatus`). `unknown` when the lab
/// reported no usable bounds. Inclusive bounds: a value on the limit reads
/// in-range.
///
/// **NEUTRAL render contract (CONTRACT FACTS):** the badge rendering this stays
/// calm + informative. ``badgeTone`` maps every case to a NON-critical
/// `HLBadge.Tone` (`.info` / `.neutral`) — never `.critical`/red — so an
/// out-of-range value is *informative*, not an alarm.
public enum LabRangeStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case inRange = "in-range"
    case below
    case above
    case unknown

    /// Tolerant decode: an unknown wire string falls back to ``unknown`` rather
    /// than failing the whole `LabResult` decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LabRangeStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - LabResultDTO (list row)

/// One stored lab result as returned by `GET /api/labs`. List rows omit the
/// encrypted note; ``hasNote`` flags its presence (the decrypted note is only
/// returned by the single-resource GET — see ``LabResultDetailDTO``).
public struct LabResultDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// Links the user-scoped catalog marker. `nil` for legacy free-text rows.
    /// When set, `analyte`/`unit`/`referenceLow`/`referenceHigh` are
    /// server-resolved — render, never recompute.
    public let biomarkerId: String?
    public let panel: String?
    public let analyte: String
    /// The numeric reading, or `nil` when the row carries no number — either
    /// because the result is QUALITATIVE (see ``valueText``) or because the
    /// server genuinely omitted the measurement.
    ///
    /// **Was a non-optional `Double` before Build 1 / item 1.5.** A qualitative
    /// web row (`{"value": null, "valueText": "negativ"}`) decoded to a
    /// fabricated `0` and rendered as an empty measurement. `nil` is now the
    /// honest representation and every read site must handle it.
    public let value: Double?
    /// v1.18.9 — the qualitative result text ("negativ" / "positiv" /
    /// "grenzwertig" / free text). `nil` for a numeric row. Mutually exclusive
    /// with ``value`` in practice (the server writes one or the other).
    public let valueText: String?
    /// `true` when the row carries NO reading at all — neither a number nor a
    /// qualitative text. The FHIR exporter emits `Observation.dataAbsentReason`
    /// for these instead of a misleading `valueQuantity: 0`.
    ///
    /// Derived, not on the wire. A qualitative row is NOT absent — it has a
    /// result, just not a numeric one (it exports as `valueString`).
    public var valueIsAbsent: Bool {
        value == nil && (valueText?.isEmpty ?? true)
    }

    /// `true` when this row's result is qualitative (a non-empty ``valueText``).
    public var isQualitative: Bool {
        !(valueText?.isEmpty ?? true)
    }

    public let unit: String
    public let referenceLow: Double?
    public let referenceHigh: Double?
    /// `YYYY-MM-DDTHH:mm:ssZ`.
    public let takenAt: String
    public let source: String
    public let hasNote: Bool
    /// Raw status string is decoded into the typed, NEUTRAL ``LabRangeStatus``.
    public let rangeStatus: LabRangeStatus
    public let createdAt: String
    public let updatedAt: String
    /// #126 P2 (v1.42.3) — the server converted the printed value into the
    /// marker's unit. The printed value and unit stay in ``sourceValue`` /
    /// ``sourceUnit``; ``printedReferenceText`` is the range as printed. All
    /// optional (older servers send none). Decoded now, shown later.
    public let converted: Bool?
    public let sourceValue: Double?
    public let sourceUnit: String?
    public let printedReferenceText: String?

    /// True when this row is linked to a catalog biomarker (analyte / unit /
    /// range are server-resolved + must be read-only in the editor).
    public var isLinked: Bool {
        biomarkerId != nil
    }

    public init(
        id: String,
        biomarkerId: String?,
        panel: String?,
        analyte: String,
        value: Double?,
        valueText: String? = nil,
        unit: String,
        referenceLow: Double?,
        referenceHigh: Double?,
        takenAt: String,
        source: String,
        hasNote: Bool,
        rangeStatus: LabRangeStatus,
        createdAt: String,
        updatedAt: String,
        converted: Bool? = nil,
        sourceValue: Double? = nil,
        sourceUnit: String? = nil,
        printedReferenceText: String? = nil
    ) {
        self.id = id
        self.biomarkerId = biomarkerId
        self.panel = panel
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.takenAt = takenAt
        self.source = source
        self.hasNote = hasNote
        self.rangeStatus = rangeStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.converted = converted
        self.sourceValue = sourceValue
        self.sourceUnit = sourceUnit
        self.printedReferenceText = printedReferenceText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        biomarkerId = try c.decodeIfPresent(String.self, forKey: .biomarkerId)
        panel = try c.decodeIfPresent(String.self, forKey: .panel)
        analyte = try c.decodeIfPresent(String.self, forKey: .analyte) ?? ""
        // A missing OR explicitly-null `value` key decodes to `nil` — NEVER a
        // fabricated 0. `valueIsAbsent` derives from that, so the FHIR exporter
        // still emits `dataAbsentReason` rather than a misleading
        // `valueQuantity: 0`, while a qualitative row keeps its `valueText`.
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        valueText = try c.decodeIfPresent(String.self, forKey: .valueText)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        referenceLow = try c.decodeIfPresent(Double.self, forKey: .referenceLow)
        referenceHigh = try c.decodeIfPresent(Double.self, forKey: .referenceHigh)
        takenAt = try c.decodeIfPresent(String.self, forKey: .takenAt) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "MANUAL"
        hasNote = try c.decodeIfPresent(Bool.self, forKey: .hasNote) ?? false
        rangeStatus = try c.decodeIfPresent(LabRangeStatus.self, forKey: .rangeStatus) ?? .unknown
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        converted = try? c.decodeIfPresent(Bool.self, forKey: .converted)
        sourceValue = try? c.decodeIfPresent(Double.self, forKey: .sourceValue)
        sourceUnit = try? c.decodeIfPresent(String.self, forKey: .sourceUnit)
        printedReferenceText = try? c.decodeIfPresent(String.self, forKey: .printedReferenceText)
    }

    /// Explicit keys — `valueIsAbsent` / `isQualitative` are derived, off-wire
    /// and must NOT be encoded (a synthesized `CodingKeys` would include stored
    /// properties only, but keeping the list explicit documents the wire shape).
    private enum CodingKeys: String, CodingKey {
        case id, biomarkerId, panel, analyte, value, valueText, unit
        case referenceLow, referenceHigh, takenAt, source, hasNote
        case rangeStatus, createdAt, updatedAt
        case converted, sourceValue, sourceUnit, printedReferenceText
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(biomarkerId, forKey: .biomarkerId)
        try c.encodeIfPresent(panel, forKey: .panel)
        try c.encode(analyte, forKey: .analyte)
        // Preserve absence across a round-trip: omit `value` when there is none.
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(valueText, forKey: .valueText)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(referenceLow, forKey: .referenceLow)
        try c.encodeIfPresent(referenceHigh, forKey: .referenceHigh)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encode(source, forKey: .source)
        try c.encode(hasNote, forKey: .hasNote)
        try c.encode(rangeStatus, forKey: .rangeStatus)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(converted, forKey: .converted)
        try c.encodeIfPresent(sourceValue, forKey: .sourceValue)
        try c.encodeIfPresent(sourceUnit, forKey: .sourceUnit)
        try c.encodeIfPresent(printedReferenceText, forKey: .printedReferenceText)
    }
}

// MARK: - LabResultDetailDTO (single GET)

/// Single lab result from `GET /api/labs/{id}` — same fields as
/// ``LabResultDTO`` minus `hasNote`, plus the decrypted ``note``.
public struct LabResultDetailDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let biomarkerId: String?
    public let panel: String?
    public let analyte: String
    /// Carries the same absence semantics as ``LabResultDTO/value``.
    /// The detail GET previously defaulted a missing/null `value` to `0`, so the
    /// detail screen of a qualitative row read "0" where the list read "".
    public let value: Double?
    /// v1.18.9 qualitative result text; `nil` for a numeric row.
    public let valueText: String?
    public let unit: String
    public let referenceLow: Double?
    public let referenceHigh: Double?
    public let takenAt: String
    public let source: String
    public let rangeStatus: LabRangeStatus
    public let createdAt: String
    public let updatedAt: String
    /// Decrypted free-text note (server-side decryption) or `nil`.
    public let note: String?
    /// #126 P2 (v1.42.3) — see ``LabResultDTO/converted``. Decoded only.
    public let converted: Bool?
    public let sourceValue: Double?
    public let sourceUnit: String?
    public let printedReferenceText: String?
    /// #141 (v1.43) — related records; `nil` from an older server.
    public internal(set) var related: RelatedLinks?

    public var isLinked: Bool {
        biomarkerId != nil
    }

    /// No reading at all — neither number nor qualitative text.
    public var valueIsAbsent: Bool {
        value == nil && (valueText?.isEmpty ?? true)
    }

    /// `true` when this row's result is qualitative.
    public var isQualitative: Bool {
        !(valueText?.isEmpty ?? true)
    }

    public init(
        id: String,
        biomarkerId: String?,
        panel: String?,
        analyte: String,
        value: Double?,
        valueText: String? = nil,
        unit: String,
        referenceLow: Double?,
        referenceHigh: Double?,
        takenAt: String,
        source: String,
        rangeStatus: LabRangeStatus,
        createdAt: String,
        updatedAt: String,
        note: String?,
        converted: Bool? = nil,
        sourceValue: Double? = nil,
        sourceUnit: String? = nil,
        printedReferenceText: String? = nil
    ) {
        self.id = id
        self.biomarkerId = biomarkerId
        self.panel = panel
        self.analyte = analyte
        self.value = value
        self.valueText = valueText
        self.unit = unit
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
        self.takenAt = takenAt
        self.source = source
        self.rangeStatus = rangeStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.note = note
        self.converted = converted
        self.sourceValue = sourceValue
        self.sourceUnit = sourceUnit
        self.printedReferenceText = printedReferenceText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        biomarkerId = try c.decodeIfPresent(String.self, forKey: .biomarkerId)
        panel = try c.decodeIfPresent(String.self, forKey: .panel)
        analyte = try c.decodeIfPresent(String.self, forKey: .analyte) ?? ""
        // No `?? 0`. Absence stays absence.
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        valueText = try c.decodeIfPresent(String.self, forKey: .valueText)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        referenceLow = try c.decodeIfPresent(Double.self, forKey: .referenceLow)
        referenceHigh = try c.decodeIfPresent(Double.self, forKey: .referenceHigh)
        takenAt = try c.decodeIfPresent(String.self, forKey: .takenAt) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "MANUAL"
        rangeStatus = try c.decodeIfPresent(LabRangeStatus.self, forKey: .rangeStatus) ?? .unknown
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        converted = try? c.decodeIfPresent(Bool.self, forKey: .converted)
        sourceValue = try? c.decodeIfPresent(Double.self, forKey: .sourceValue)
        sourceUnit = try? c.decodeIfPresent(String.self, forKey: .sourceUnit)
        printedReferenceText = try? c.decodeIfPresent(String.self, forKey: .printedReferenceText)
        related = try? c.decodeIfPresent(RelatedLinks.self, forKey: .related)
    }
}

// MARK: - BiomarkerDTO

/// A user-scoped catalog marker (`Biomarker`). A `LabResult` linking this marker
/// resolves its unit + reference bounds from here. ``context`` is the decrypted
/// per-marker note (or `nil`); ``hasContext`` flags its presence.
public struct BiomarkerDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let unit: String
    public let lowerBound: Double?
    public let upperBound: Double?
    public let panel: String?
    public let hasContext: Bool
    public let context: String?
    /// Build 3 / item 3.2 — server `Biomarker.hidden` (Prisma column, default
    /// `false`; wire field emitted by `GET /api/biomarkers`
    /// (`src/app/api/biomarkers/route.ts:53,67`) and settable through
    /// `updateBiomarkerSchema.hidden`).
    ///
    /// "A marker the user no longer needs: dropped from the active catalog list
    /// and from the lab-entry pickers, but never deleted — its readings and
    /// canonical unit/range definition survive." iOS had no pendant, so a
    /// marker the user hid on the web kept showing up in the iPhone picker.
    ///
    /// **Read sites must FILTER, not delete.** A hidden marker's historical
    /// results still render (they are real readings against a real definition);
    /// only the pickers and the active catalog list drop it.
    ///
    /// Defaults to `false` on decode so a pre-v1.22 server (or any fixture
    /// without the key) keeps every marker visible — the safe direction.
    public let hidden: Bool
    public let createdAt: String
    public let updatedAt: String
    /// #130 (v1.43) — other spellings that map to this marker (sorted, without
    /// the marker's own name). Empty from a server that does not send them.
    /// Read-only here; editing aliases and merging are a later unit.
    public let aliases: [String]

    public init(
        id: String,
        name: String,
        unit: String,
        lowerBound: Double?,
        upperBound: Double?,
        panel: String?,
        hasContext: Bool,
        context: String?,
        hidden: Bool = false,
        createdAt: String,
        updatedAt: String,
        aliases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.panel = panel
        self.hasContext = hasContext
        self.context = context
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        lowerBound = try c.decodeIfPresent(Double.self, forKey: .lowerBound)
        upperBound = try c.decodeIfPresent(Double.self, forKey: .upperBound)
        panel = try c.decodeIfPresent(String.self, forKey: .panel)
        hasContext = try c.decodeIfPresent(Bool.self, forKey: .hasContext) ?? false
        context = try c.decodeIfPresent(String.self, forKey: .context)
        // Absent key → visible. Never hide a marker because a field was missing.
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
    }
}

public extension Collection<BiomarkerDTO> {
    /// Build 3 / item 3.2 — the markers a PICKER may offer. Mirrors the web
    /// filter (`lab-form.tsx:137`). Keep this the single definition so no
    /// picker forgets it.
    var selectable: [BiomarkerDTO] {
        filter { !$0.hidden }
    }
}

// MARK: - List envelopes (the `data` payload `APIClient.send` unwraps)

/// Pagination meta on `GET /api/labs` (`{ total, limit, offset }`).
public struct LabResultsListMeta: Codable, Sendable, Equatable, Hashable {
    public let total: Int
    public let limit: Int
    public let offset: Int

    public init(total: Int, limit: Int, offset: Int) {
        self.total = total
        self.limit = limit
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 0
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

/// `GET /api/labs` → `data` = `{ results: [LabResult], meta: {…} }`.
/// (`APIClient.send` already strips the outer `{ data, error, meta }` envelope.)
public struct ListLabResultsResponse: Codable, Sendable, Equatable {
    public let results: [LabResultDTO]
    public let meta: LabResultsListMeta?

    public init(results: [LabResultDTO], meta: LabResultsListMeta? = nil) {
        self.results = results
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([LabResultDTO].self, forKey: .results) ?? []
        meta = try c.decodeIfPresent(LabResultsListMeta.self, forKey: .meta)
    }
}

/// `GET /api/biomarkers` → `data` = `{ biomarkers: [Biomarker] }`.
public struct ListBiomarkersResponse: Codable, Sendable, Equatable {
    public let biomarkers: [BiomarkerDTO]
    /// The person's own panel names, one spelling each (server v1.47.1,
    /// #164): the suggestions under the marker form's panel field. Empty
    /// on an older server, which then offers none.
    public let customPanels: [String]

    public init(biomarkers: [BiomarkerDTO], customPanels: [String] = []) {
        self.biomarkers = biomarkers
        self.customPanels = customPanels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        biomarkers = try c.decodeIfPresent([BiomarkerDTO].self, forKey: .biomarkers) ?? []
        customPanels = ((try? c.decodeIfPresent([String].self, forKey: .customPanels)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Marker overview

/// `GET /api/labs/overview` → `data` = `{ markers, categories, grouped }`
/// (server v1.42.4+; `categories` and `grouped` from the release that groups
/// the list). One entry per marker over the WHOLE history, not paged,
/// so a marker measured only years ago is never cut off by a page size. This is
/// the source of the labs list; `GET /api/labs?limit=` is not.
///
/// `categories` are the list's groups as the server resolved them: label in
/// the caller's language, members, counts and a combined status, already in
/// the caller's order (the server applies `categoryOrder` of the list layout,
/// so no order is sent beside them). A client renders them as given and never
/// rebuilds them. `grouped` says whether grouping adds anything; while it is
/// `false` (or against a server without categories) the list is flat.
///
/// Lossy: a marker or a category this build cannot read is skipped, the rest
/// still render.
public struct LabOverviewResponse: Codable, Sendable, Equatable {
    public let markers: [LabOverviewMarker]
    public let categories: [LabOverviewCategory]
    public let grouped: Bool

    public init(markers: [LabOverviewMarker], categories: [LabOverviewCategory] = [], grouped: Bool = false) {
        self.markers = markers
        self.categories = categories
        self.grouped = grouped
    }

    private enum CodingKeys: String, CodingKey {
        case markers, categories, grouped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `markers` is required: a body without it is not an overview (a
        // fixture or proxy answering with some other shape) and must fail, so
        // the store keeps its fallback instead of showing an empty list.
        markers = try c.decode([FailableMarker].self, forKey: .markers).compactMap(\.marker)
        categories = ((try? c.decodeIfPresent([FailableCategory].self, forKey: .categories)) ?? [])
            .compactMap(\.category)
        grouped = (try? c.decodeIfPresent(Bool.self, forKey: .grouped)) ?? false
    }

    private struct FailableMarker: Decodable {
        let marker: LabOverviewMarker?

        init(from decoder: Decoder) throws {
            marker = try? LabOverviewMarker(from: decoder)
        }
    }

    private struct FailableCategory: Decodable {
        let category: LabOverviewCategory?

        init(from decoder: Decoder) throws {
            category = try? LabOverviewCategory(from: decoder)
        }
    }
}

/// How many members of a category have their newest reading in range, below,
/// above, or unassessed (qualitative, or without a range).
public struct LabOverviewCategoryCounts: Codable, Sendable, Equatable {
    public let inRange: Int
    public let below: Int
    public let above: Int
    public let unknown: Int

    public init(inRange: Int = 0, below: Int = 0, above: Int = 0, unknown: Int = 0) {
        self.inRange = inRange
        self.below = below
        self.above = above
        self.unknown = unknown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inRange = (try? c.decodeIfPresent(Int.self, forKey: .inRange)) ?? 0
        below = (try? c.decodeIfPresent(Int.self, forKey: .below)) ?? 0
        above = (try? c.decodeIfPresent(Int.self, forKey: .above)) ?? 0
        unknown = (try? c.decodeIfPresent(Int.self, forKey: .unknown)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case inRange, below, above, unknown
    }
}

/// One category of the labs list, resolved by the server. `key` is opaque (a
/// catalog panel key, `custom:<hash>` or `other`) and stable, `label` is shown
/// as sent, `markerKeys` names the ``LabOverviewMarker/key`` values it holds,
/// `status` is the combined, neutral verdict of the members' newest readings.
public struct LabOverviewCategory: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let markerKeys: [String]
    public let counts: LabOverviewCategoryCounts
    public let status: LabRangeStatus

    public var id: String {
        key
    }

    public init(
        key: String,
        label: String,
        markerKeys: [String],
        counts: LabOverviewCategoryCounts = LabOverviewCategoryCounts(),
        status: LabRangeStatus = .unknown
    ) {
        self.key = key
        self.label = label
        self.markerKeys = markerKeys
        self.counts = counts
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, markerKeys, counts, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        markerKeys = (try? c.decodeIfPresent([String].self, forKey: .markerKeys)) ?? []
        counts = (try? c.decodeIfPresent(LabOverviewCategoryCounts.self, forKey: .counts)) ?? LabOverviewCategoryCounts()
        status = (try? c.decodeIfPresent(LabRangeStatus.self, forKey: .status)) ?? .unknown
    }
}

/// One marker of the caller's lab history: `key` is `bm:<biomarkerId>` for a
/// catalog-linked marker or `analyte:<lower-cased name>` for an unlinked one,
/// `count` is every live reading, `trend` the values of the newest readings
/// (at most 50, oldest first, `nil` for a qualitative one), `latest` the newest
/// reading exactly like a `GET /api/labs` row.
public struct LabOverviewMarker: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let count: Int
    public let trend: [Double?]
    public let latest: LabResultDTO

    public var id: String {
        key
    }

    /// The catalog marker id when `key` is `bm:<id>`, else `nil`.
    public var biomarkerId: String? {
        guard key.hasPrefix("bm:") else { return nil }
        let id = String(key.dropFirst(3))
        return id.isEmpty ? nil : id
    }

    public init(key: String, count: Int, trend: [Double?] = [], latest: LabResultDTO) {
        self.key = key
        self.count = count
        self.trend = trend
        self.latest = latest
    }

    private enum CodingKeys: String, CodingKey {
        case key, count, trend, latest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        latest = try c.decode(LabResultDTO.self, forKey: .latest)
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 1
        trend = (try? c.decodeIfPresent([Double?].self, forKey: .trend)) ?? []
    }
}

/// `POST /api/labs/restore` → `data` = `{ restored: number }`.
public struct RestoreLabResultsResponse: Codable, Sendable, Equatable {
    public let restored: Int

    public init(restored: Int) {
        self.restored = restored
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restored = try c.decodeIfPresent(Int.self, forKey: .restored) ?? 0
    }
}

/// `DELETE /api/labs/{id}` + `DELETE /api/biomarkers/{id}` → `data` =
/// `{ deleted: bool }`.
public struct DeletedFlagResponse: Codable, Sendable, Equatable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}
