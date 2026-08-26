import Foundation

// Wire READ DTOs for the user-defined custom-metric store (server v1.25.5,
// `/api/custom-metrics`).
//
// Source of truth (read 2026-07-19 from the SERVER repo, not the web
// components):
//   - `src/lib/custom-metrics/custom-metric-store.ts` — `serialiseCustomMetric`
//     / `serialiseCustomMetricWithLatest` / `serialiseCustomMetricEntry` are the
//     ONLY three shapes the four routes emit.
//   - `src/lib/validations/custom-metrics.ts` — the write schemas.
//   - `prisma/schema.prisma` → `model CustomMetric` / `model CustomMetricEntry`.
//
// CONTRACT FACTS the client must honour:
//   - The store is deliberately ISOLATED from the closed `MeasurementType`
//     system: not synced, not in FHIR, not in AI insights — "log + chart only"
//     (the server's own words). Nothing here may leak into the sync or FHIR
//     paths.
//   - `unit` is SNAPSHOTTED onto each entry server-side at write time
//     (historical truth, mirroring the LabResult per-row unit). The client MUST
//     render the entry's own `unit`, never re-stamp it from the metric — a
//     renamed unit must not rewrite history.
//   - `latest` + `entryCount` are LIST-ONLY enrichment. `GET /{id}` returns the
//     bare `serialiseCustomMetric` shape WITHOUT them, so both decode optional.
//   - The target window is the user's own "good range", charted as a NEUTRAL
//     reference band. Both bounds are independently optional. It is NOT a
//     clinical reference range and must never render as an alarm.
//
// Every struct is `Sendable` + `Codable` with **tolerant decode**
// (`decodeIfPresent` + safe defaults) so a field added later never hard-fails
// the envelope (`MedicationInventoryItemDTO` / `CycleDTO` precedent). Timestamps
// stay raw ISO-8601 `String`s, matching `LabsDTO` — `LabsDateFormat.parse`
// is the shared reader.

// MARK: - CustomMetricLatestDTO

/// The most recent logged value, embedded in each row of the LIST read
/// (`GET /api/custom-metrics`). Carries the entry's own snapshotted `unit`, not
/// the metric's current one.
public struct CustomMetricLatestDTO: Codable, Sendable, Equatable, Hashable {
    /// The reading. Optional on the client even though the server column is
    /// non-null: a fabricated `0` for a missing number is exactly the bug the
    /// labs surface shipped and had to unwind (audit A3 / item 1.5). `nil` is
    /// the honest representation and every read site handles it.
    public let value: Double?
    /// Unit snapshot taken when the value was logged.
    public let unit: String
    /// `YYYY-MM-DDTHH:mm:ss.sssZ`.
    public let measuredAt: String

    public init(value: Double?, unit: String, measuredAt: String) {
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        measuredAt = try c.decodeIfPresent(String.self, forKey: .measuredAt) ?? ""
    }
}

// MARK: - CustomMetricDTO

/// One user-defined metric definition. Returned bare by `GET /{id}` and
/// `PATCH /{id}`, and enriched with ``latest`` + ``entryCount`` by the list read.
public struct CustomMetricDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// Free-text display name, e.g. "Morning grip strength". Unique per user
    /// (`@@unique([userId, name])`) — a duplicate is a `409`.
    public let name: String
    /// Free-text unit label, e.g. "kg", "reps", "score".
    public let unit: String
    /// Optional target window ("my good range"). Charted as a NEUTRAL band —
    /// never a red/green verdict. Both bounds independently optional.
    public let targetLow: Double?
    public let targetHigh: Double?
    /// Optional fixed decimal places for display. `nil` → the app's sensible
    /// default (see ``CustomMetricFormat``). Server-capped to `0...6`.
    public let decimals: Int?
    /// Optional free-text "what this measures". Plaintext (no encryption layer
    /// on this store, unlike the Biomarker `contextEncrypted` codec).
    public let description: String?
    /// **CU-35 (3)** — whether this metric takes part in the correlation
    /// analysis. Server column with default `false`; `serialiseCustomMetric`
    /// emits it on every read. A build (or fixture) that predates the field
    /// decodes to `false`, which is both the server default and the safe
    /// reading: never assume a consent that was not stated.
    public let correlationEnabled: Bool
    public let createdAt: String
    public let updatedAt: String

    /// LIST-ONLY: the most recent logged value. `nil` on a single-resource read
    /// (the server's `serialiseCustomMetric` omits the key entirely) AND for a
    /// metric that has no values yet — the two are indistinguishable on the
    /// wire, so a `nil` here means "no latest value to show", never "loading".
    public let latest: CustomMetricLatestDTO?
    /// LIST-ONLY: total logged values. `0` on a single-resource read.
    public let entryCount: Int

    public init(
        id: String,
        name: String,
        unit: String,
        targetLow: Double? = nil,
        targetHigh: Double? = nil,
        decimals: Int? = nil,
        description: String? = nil,
        correlationEnabled: Bool = false,
        createdAt: String = "",
        updatedAt: String = "",
        latest: CustomMetricLatestDTO? = nil,
        entryCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.targetLow = targetLow
        self.targetHigh = targetHigh
        self.decimals = decimals
        self.description = description
        self.correlationEnabled = correlationEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.latest = latest
        self.entryCount = entryCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        targetLow = try c.decodeIfPresent(Double.self, forKey: .targetLow)
        targetHigh = try c.decodeIfPresent(Double.self, forKey: .targetHigh)
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        correlationEnabled = try c.decodeIfPresent(Bool.self, forKey: .correlationEnabled) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        latest = try c.decodeIfPresent(CustomMetricLatestDTO.self, forKey: .latest)
        entryCount = try c.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
    }

    /// True when the metric declares at least one target bound (so the band /
    /// status affordances have something to render).
    public var hasTargetBand: Bool {
        targetLow != nil || targetHigh != nil
    }
}

// MARK: - CustomMetricEntryDTO

/// One logged value against a ``CustomMetricDTO``. Returned by the entries list,
/// the entry POST, and the entry PATCH.
public struct CustomMetricEntryDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let customMetricId: String
    /// The reading. Optional for the same honesty reason as
    /// ``CustomMetricLatestDTO/value`` — never fabricate a `0`.
    public let value: Double?
    /// Unit SNAPSHOT from the metric at write time. Render this, not the
    /// metric's current unit: a later unit rename must not rewrite history.
    public let unit: String
    /// `YYYY-MM-DDTHH:mm:ss.sssZ`. The user-chosen instant (backdatable).
    public let measuredAt: String
    public let note: String?
    public let createdAt: String

    public init(
        id: String,
        customMetricId: String,
        value: Double?,
        unit: String,
        measuredAt: String,
        note: String? = nil,
        createdAt: String = ""
    ) {
        self.id = id
        self.customMetricId = customMetricId
        self.value = value
        self.unit = unit
        self.measuredAt = measuredAt
        self.note = note
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        customMetricId = try c.decodeIfPresent(String.self, forKey: .customMetricId) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        measuredAt = try c.decodeIfPresent(String.self, forKey: .measuredAt) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    /// True when the row carries no numeric reading at all. Such a row is kept
    /// in the list (the user still sees the entry exists) but is excluded from
    /// every derivation — plotting it would draw a phantom dip to zero.
    public var valueIsAbsent: Bool {
        value == nil
    }
}

// MARK: - List envelopes

/// `GET /api/custom-metrics` → `{ customMetrics: [...] }`.
public struct ListCustomMetricsResponse: Codable, Sendable, Equatable {
    public let customMetrics: [CustomMetricDTO]

    public init(customMetrics: [CustomMetricDTO]) {
        self.customMetrics = customMetrics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customMetrics = try c.decodeIfPresent([CustomMetricDTO].self, forKey: .customMetrics) ?? []
    }
}

/// Offset-pagination meta on the entries feed (`{ total, limit, offset }`).
public struct CustomMetricEntriesMeta: Codable, Sendable, Equatable {
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

/// `GET /api/custom-metrics/{id}/entries` → `{ entries, meta }`.
public struct ListCustomMetricEntriesResponse: Codable, Sendable, Equatable {
    public let entries: [CustomMetricEntryDTO]
    public let meta: CustomMetricEntriesMeta

    public init(entries: [CustomMetricEntryDTO], meta: CustomMetricEntriesMeta) {
        self.entries = entries
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([CustomMetricEntryDTO].self, forKey: .entries) ?? []
        meta = try c.decodeIfPresent(CustomMetricEntriesMeta.self, forKey: .meta)
            ?? CustomMetricEntriesMeta(total: entries.count, limit: entries.count, offset: 0)
    }
}
