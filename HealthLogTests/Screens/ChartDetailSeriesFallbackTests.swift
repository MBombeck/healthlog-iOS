import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

/// Pin the DASHBOARD-CHARTS-BUG-FIX (2026-05-16) series-points fallback path
/// — the `measurementsFromSeriesPoints` helper synthesizes lightweight
/// `Measurement` rows from `SeriesPoint`s so the store can derive a useful
/// `MetricDataState` when the recent-page fan-out fails but the series
/// request succeeded.
///
/// Operator-reported symptom these tests defend against: "ChartDetail laedt,
/// aber kein Graph erscheint." Root-cause was a hard `switch store.dataState`
/// gate that blocked the chart whenever the second (recent-page) fetch was
/// in-flight or had failed. The UI now short-circuits on `series`, and the
/// store additionally synthesizes a `.ready` state from the series points
/// so the dataState-keyed Stats / DrillDown rows render correctly too.
@Suite("ChartDetailStore.measurementsFromSeriesPoints — series-to-measurement mapping")
struct ChartDetailSeriesFallbackTests {
    @Test("Single-scalar series point maps to scalar Measurement carrying the same value + date")
    func scalarSeriesPointMapsToScalarMeasurement() throws {
        let now = Date.now
        let point = SeriesPoint(id: "pt-1", at: now, value: 86.9, secondary: nil)
        let measurements = ChartDetailStore.measurementsFromSeriesPoints([point], kind: .weight)
        #expect(measurements.count == 1)
        let measurement = try #require(measurements.first)
        #expect(measurement.id == "pt-1")
        #expect(measurement.kind == .weight)
        #expect(measurement.recordedAt == now)
        if case let .scalar(value) = measurement.value {
            #expect(value == 86.9)
        } else {
            Issue.record("Expected .scalar, got \(measurement.value)")
        }
    }

    @Test("BP series point (secondary set) maps to bloodPressure Measurement preserving sys/dia")
    func bloodPressurePointMapsToCompoundMeasurement() throws {
        let point = SeriesPoint(id: "pt-bp", at: .now, value: 124, secondary: 78)
        let measurements = ChartDetailStore.measurementsFromSeriesPoints([point], kind: .bloodPressure)
        #expect(measurements.count == 1)
        let measurement = try #require(measurements.first)
        if case let .bloodPressure(sys, dia) = measurement.value {
            #expect(sys == 124)
            #expect(dia == 78)
        } else {
            Issue.record("Expected .bloodPressure, got \(measurement.value)")
        }
    }

    @Test("Empty series-points produces empty measurements (no crash)")
    func emptySeriesProducesEmptyMeasurements() {
        let measurements = ChartDetailStore.measurementsFromSeriesPoints([], kind: .pulse)
        #expect(measurements.isEmpty)
    }

    @Test("Multi-point series preserves order + every row carries the supplied kind")
    func multiPointSeriesPreservesOrderAndKind() {
        let base = Date.now
        let points = (0 ..< 5).map { idx in
            SeriesPoint(id: "p-\(idx)", at: base.addingTimeInterval(Double(idx) * 86400), value: Double(idx + 70), secondary: nil)
        }
        let measurements = ChartDetailStore.measurementsFromSeriesPoints(points, kind: .pulse)
        #expect(measurements.count == 5)
        for (idx, measurement) in measurements.enumerated() {
            #expect(measurement.kind == .pulse)
            #expect(measurement.id == "p-\(idx)")
        }
    }

    @Test("Synthesized rows are source=.manual (we can't recover the real provenance from series payload)")
    func syntheticRowsAreManualSource() throws {
        let point = SeriesPoint(id: "pt-1", at: .now, value: 1, secondary: nil)
        let measurements = ChartDetailStore.measurementsFromSeriesPoints([point], kind: .glucose)
        let measurement = try #require(measurements.first)
        // The series endpoint does not emit per-point source today; the
        // synthetic fallback attributes every row to `.manual`. Whoever
        // consumes the dataState only needs the count + dates to render
        // a sensible empty/ready predicate.
        #expect(measurement.source == .manual)
    }

    @Test("Synthetic measurements feed MetricDataState.derive into a .ready state")
    func syntheticMeasurementsDeriveReadyState() {
        let now = Date.now
        let points = [
            SeriesPoint(id: "p1", at: now.addingTimeInterval(-5 * 86400), value: 86.1, secondary: nil),
            SeriesPoint(id: "p2", at: now.addingTimeInterval(-3 * 86400), value: 86.5, secondary: nil),
            SeriesPoint(id: "p3", at: now.addingTimeInterval(-1 * 86400), value: 86.9, secondary: nil)
        ]
        let measurements = ChartDetailStore.measurementsFromSeriesPoints(points, kind: .weight)
        let state = MetricDataState.derive(
            allSamples: measurements,
            inRange: measurements,
            sourceFilterApplied: false
        )
        guard case let .ready(latest, samples) = state else {
            Issue.record("Expected .ready, got \(state)")
            return
        }
        #expect(samples.count == 3)
        // Latest = newest recordedAt (-1 day in this set).
        #expect(latest.id == "p3")
    }
}
