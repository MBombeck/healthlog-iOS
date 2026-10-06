import Foundation

// MARK: - #115 R3 — synthetic server ids are not measurement rows

/// The measurement read routes hand out points and rows whose `id` is a
/// **synthetic key**, not a stored row id (OpenAPI `SeriesPoint.id` /
/// `MeasurementRow.id` at server v1.39.6):
///
/// - `day:<YYYY-MM-DD>` — a day bucket on `GET /api/measurements/series`
///   (`pulse` / `glucose` past 90 days; from v1.39.7 also HRV and SpO2).
/// - `hour:<ISO instant>` — an hour bucket on the same route, inside 90 days
///   when the window holds more than 10 000 readings (a per-minute pulse stream,
///   a CGM; since v1.39.5 / v1.39.6, HRV and SpO2 from v1.39.7).
/// - `day:<TYPE>:<YYYY-MM-DD>` — a day-collapsed row on
///   `GET /api/measurements?groupBy=day` (the cumulative kinds).
/// - `sleep:<wake-day>` / `sleep-seg:<day>:<n>` — a sleep night / segment.
///
/// The value is a mean (with the bucket's low/high in `valueMin`/`valueMax`) or
/// a total; there is no row behind it, so `PUT` / `DELETE
/// /api/measurements/<id>` answer 404. The app synthesises `Measurement`s from
/// such points in several places (list fallback, chart-detail state, the
/// cumulative `recent(kind:)` path), so every edit and delete path asks this
/// first. Real ids are cuids (no colon), local optimistic ids start with
/// `local-`, standalone ids with `hk-` — none of them can match.
public extension Measurement {
    /// The id prefixes the server uses for synthetic, non-row keys.
    static let syntheticServerRowIDPrefixes: [String] = ["day:", "hour:", "sleep:", "sleep-seg:"]

    /// `true` when `id` is a synthetic server key (see the type note), never a
    /// stored measurement.
    static func isSyntheticServerRowID(_ id: String) -> Bool {
        syntheticServerRowIDPrefixes.contains { id.hasPrefix($0) }
    }

    /// `true` when this measurement was synthesised from a bucket/aggregate
    /// point and therefore cannot be edited, deleted or looked up by id.
    var isSyntheticServerRow: Bool {
        Self.isSyntheticServerRowID(id)
    }
}
