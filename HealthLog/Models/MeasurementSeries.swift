// Audit B-4 — the list/series read-path wire shapes move out of
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
/// **W-B187 (#29) — server unit-at-source.** Since server v1.16.16 the
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
    /// W-B187 (#29) — the server-resolved display unit for this series (v1.16.16
    /// unit-at-source). `nil` on an older server / a kind the server doesn't
    /// unit-stamp → the consumer falls back to the per-`MetricKind` default.
    public let unit: String?

    public init(kind: MetricKind, points: [SeriesPoint], stats: SeriesStats, unit: String? = nil) {
        self.kind = kind
        self.points = points
        self.stats = stats
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, points, stats, unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MetricKind.self, forKey: .kind)
        points = try c.decode([SeriesPoint].self, forKey: .points)
        stats = try c.decode(SeriesStats.self, forKey: .stats)
        // Tolerant: absent OR JSON `null` both decode to `nil` (older server).
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
    }

    /// The display unit label for this series — the server-resolved `unit`
    /// (v1.16.16 unit-at-source) when present, else the per-`MetricKind`
    /// hardcoded default. HONEST-ONLY: the server value is authoritative and is
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
