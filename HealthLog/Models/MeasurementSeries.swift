// The list/series read-path wire shapes move out of
// `Measurement.swift`. **Pure move** (same module, same access levels, same
// behaviour); only the file boundary changes. `MetricKind` gained two cases so
// no server measurement type is dropped any more, and `Measurement.swift` sits
// against a baselined length ceiling — these five response shapes are the piece
// with the cleanest boundary, so they pay for the lines.
import Foundation

/// List-Endpoint-Wrapper. Server liefert `{ measurements: [...], meta: {...} }`.
public struct MeasurementListResponse: Codable, Sendable {
    public let measurements: [Measurement]
    public let meta: ListMeta?

    public struct ListMeta: Codable, Sendable {
        public let total: Int?
        public let limit: Int?
        public let offset: Int?
    }
}

/// Series-Endpoint Antwort.
///
/// **Server unit-at-source.** Since server v1.16.16 the
/// `GET /api/measurements/series` payload carries an explicit `unit` token
/// (e.g. glucose `"mg/dL"` | `"mmol/L"`, per the user's preference) and the
/// `points[].value` + `stats` are ALREADY CONVERTED to that unit server-side —
/// iOS must NOT re-convert (no client `convertGlucose` runs on series points;
/// re-converting would be the 18× double-convert hazard). Read `unit` from the
/// payload and use it as the display label; never assume mg/dL. The field is
/// decoded leniently (`decodeIfPresent`) so an older server that omits it keeps
/// today's behaviour (the per-`MetricKind` hardcoded unit). Resolve the display
/// label through ``resolvedUnit(for:)`` so the consumer never hardcodes.
public struct MeasurementSeries: Codable, Sendable {
    public let kind: MetricKind
    public let points: [SeriesPoint]
    public let stats: SeriesStats
    /// The server-resolved display unit for this series (v1.16.16
    /// unit-at-source). `nil` on an older server / a kind the server doesn't
    /// unit-stamp → the consumer falls back to the per-`MetricKind` default.
    public let unit: String?
    /// #135 (server v1.43) — which way a change of this metric counts for this
    /// person. `nil` on an older server: the change stays uncoloured.
    public let direction: TrendVerdict?
    /// First and last day value of the window and how that change
    /// counts. `nil` under two days and on an older server.
    public let change: SeriesChange?
    /// The lines the server asks the chart to draw, in this series'
    /// unit. `nil` on a server before v1.43, `[]` when there is nothing to draw.
    public let referenceLines: [SeriesReferenceLine]?

    public init(
        kind: MetricKind,
        points: [SeriesPoint],
        stats: SeriesStats,
        unit: String? = nil,
        direction: TrendVerdict? = nil,
        change: SeriesChange? = nil,
        referenceLines: [SeriesReferenceLine]? = nil
    ) {
        self.kind = kind
        self.points = points
        self.stats = stats
        self.unit = unit
        self.direction = direction
        self.change = change
        self.referenceLines = referenceLines
    }

    /// The same series with other points and stats (downsampled, patched,
    /// converted): the server's unit, verdict and reference lines ride along.
    public func replacing(points: [SeriesPoint], stats: SeriesStats? = nil) -> MeasurementSeries {
        MeasurementSeries(
            kind: kind,
            points: points,
            stats: stats ?? self.stats,
            unit: unit,
            direction: direction,
            change: change,
            referenceLines: referenceLines
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, points, stats, unit, direction, change, referenceLines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant like every server-owned token: a `kind` this build
        // cannot name lands on the `.unknown` sentinel and the points survive,
        // instead of failing the whole chart. A non-string is still drift.
        let rawKind = try c.decode(String.self, forKey: .kind)
        if let known = MetricKind(rawValue: rawKind) {
            kind = known
        } else {
            UnknownServerEnumLog.noteFirstSighting(
                of: rawKind, vocabulary: "series kind", consequence: "decoded as the unknown sentinel, points kept"
            )
            kind = .unknown
        }
        points = try c.decode([SeriesPoint].self, forKey: .points)
        stats = try c.decode(SeriesStats.self, forKey: .stats)
        // Tolerant: absent OR JSON `null` both decode to `nil` (older server).
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        // Additive v1.43 fields, each tolerant on its own: a block this
        // build cannot read degrades to "not sent", never a failed chart.
        direction = try? c.decodeIfPresent(TrendVerdict.self, forKey: .direction)
        change = try? c.decodeIfPresent(SeriesChange.self, forKey: .change)
        referenceLines = SeriesReferenceLine.decodeList(from: c, forKey: .referenceLines)
    }

    /// The display unit label for this series — the server-resolved `unit`
    /// (v1.16.16 unit-at-source) when present, else the per-`MetricKind`
    /// hardcoded default. The server value is authoritative and is
    /// rendered as-is; iOS never re-converts the pre-converted `points`/`stats`.
    public func resolvedUnit(for kind: MetricKind) -> String {
        if let unit, !unit.isEmpty { return unit }
        return kind.unit
    }
}

public struct SeriesPoint: Codable, Sendable, Identifiable {
    public let id: String
    public let at: Date
    public let value: Double
    public let secondary: Double? // diastolic for BP
}

public struct SeriesStats: Codable, Sendable {
    public let mean: Double
    public let min: Double
    public let max: Double
    public let stdDev: Double
    public let count: Int
}

/// Effective range für Threshold-Checks. Spiegelt Server-Logik aus `src/lib/analytics/effective-range.ts`.
public struct EffectiveRange: Codable, Sendable {
    public let kind: MetricKind
    public let warnLow: Double?
    public let warnHigh: Double?
    public let criticalLow: Double?
    public let criticalHigh: Double?
}
