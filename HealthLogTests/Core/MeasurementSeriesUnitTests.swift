import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **W-B187 (#29) — server unit-at-source for `GET /api/measurements/series`.**
///
/// Since server v1.16.16 the series payload carries an explicit `unit` token
/// (glucose `"mg/dL"` | `"mmol/L"`, per the user's preference) and the
/// `points[].value` + `stats` are ALREADY CONVERTED to it server-side. iOS must:
///
/// - DECODE `unit` (tolerant: an older server that omits it keeps today's
///   per-`MetricKind` hardcoded label).
/// - RESOLVE the display label from `unit` (server) → `kind.unit` (fallback).
/// - NEVER re-convert the pre-converted values (no client 18× double-convert):
///   the decoded `value` is the verbatim server number under the server's unit.
@Suite("MeasurementSeries unit-at-source (W-B187 #29)")
struct MeasurementSeriesUnitTests {
    private func decode(_ json: String) throws -> MeasurementSeries {
        try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(json.utf8))
    }

    // MARK: - Decode

    @Test("Series decodes an explicit server unit (glucose mmol/L)")
    func decodesExplicitUnit() throws {
        // 100 mg/dL reads as 5.5 mmol/L — the server sends the converted value
        // 5.5 AND the unit "mmol/L"; iOS stores both verbatim.
        let series = try decode(
            """
            { "kind": "glucose", "unit": "mmol/L",
              "points": [{ "id": "g1", "at": "2026-06-14T08:00:00Z", "value": 5.5 }],
              "stats": { "mean": 5.5, "min": 5.5, "max": 5.5, "stdDev": 0, "count": 1 } }
            """
        )
        #expect(series.unit == "mmol/L")
        // No double-convert: the decoded value is the server number verbatim
        // (5.5), NOT 5.5 × 18.0182 ≈ 99 (which a naive mg/dL re-read would do).
        #expect(series.points.first?.value == 5.5)
        #expect(series.stats.mean == 5.5)
    }

    @Test("Series decodes an explicit mg/dL unit verbatim")
    func decodesMgdlUnit() throws {
        let series = try decode(
            """
            { "kind": "glucose", "unit": "mg/dL",
              "points": [{ "id": "g1", "at": "2026-06-14T08:00:00Z", "value": 100 }],
              "stats": { "mean": 100, "min": 100, "max": 100, "stdDev": 0, "count": 1 } }
            """
        )
        #expect(series.unit == "mg/dL")
        #expect(series.points.first?.value == 100)
    }

    @Test("Absent unit decodes to nil (older server forward-compat)")
    func absentUnitToleratedAsNil() throws {
        let series = try decode(
            """
            { "kind": "glucose",
              "points": [{ "id": "g1", "at": "2026-06-14T08:00:00Z", "value": 95 }],
              "stats": { "mean": 95, "min": 95, "max": 95, "stdDev": 0, "count": 1 } }
            """
        )
        #expect(series.unit == nil)
        #expect(series.points.first?.value == 95)
    }

    @Test("JSON null unit decodes to nil")
    func nullUnitToleratedAsNil() throws {
        let series = try decode(
            """
            { "kind": "glucose", "unit": null,
              "points": [],
              "stats": { "mean": 0, "min": 0, "max": 0, "stdDev": 0, "count": 0 } }
            """
        )
        #expect(series.unit == nil)
    }

    // MARK: - resolvedUnit

    @Test("resolvedUnit returns the server unit when present (mmol/L)")
    func resolvedUnitPrefersServer() {
        let series = MeasurementSeries(
            kind: .glucose,
            points: [],
            stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0),
            unit: "mmol/L"
        )
        #expect(series.resolvedUnit(for: .glucose) == "mmol/L")
    }

    @Test("resolvedUnit falls back to the kind default when unit is absent")
    func resolvedUnitFallsBackToKind() {
        let series = MeasurementSeries(
            kind: .glucose,
            points: [],
            stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0),
            unit: nil
        )
        // No server unit → the hardcoded glucose default (mg/dL) — today's
        // behaviour, unchanged for every kind the server doesn't unit-stamp.
        #expect(series.resolvedUnit(for: .glucose) == "mg/dL")
        #expect(series.resolvedUnit(for: .glucose) == MetricKind.glucose.unit)
    }

    @Test("resolvedUnit falls back when the server sends an empty unit string")
    func resolvedUnitFallsBackOnEmpty() {
        let series = MeasurementSeries(
            kind: .glucose,
            points: [],
            stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0),
            unit: ""
        )
        #expect(series.resolvedUnit(for: .glucose) == "mg/dL")
    }

    @Test("Memberwise init keeps unit nil by default (no call-site churn)")
    func defaultInitKeepsUnitNil() {
        let series = MeasurementSeries(
            kind: .weight,
            points: [],
            stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
        )
        #expect(series.unit == nil)
        #expect(series.resolvedUnit(for: .weight) == "kg")
    }
}
