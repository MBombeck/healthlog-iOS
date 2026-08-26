import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

/// v0.14.3 E5 — pins the contract behind `MeasurementListScreen`'s NEW series
/// fallback ("Vital → alle Messungen anzeigen" showed "keine Einträge" though the
/// chart had data).
///
/// The drill-down list now mirrors `ChartDetailStore`'s series synthesis: when
/// `recent(kind:)` is empty/threw, it derives rows from `/series` via
/// `ChartDetailStore.measurementsFromSeriesPoints` — but ONLY for kinds the
/// series endpoint supports (`kindSupportsSeries`). These tests lock the two
/// halves of that gate so the list and the chart can never disagree again.
@Suite("MeasurementList series fallback gate (E5)")
struct MeasurementListSeriesFallbackTests {
    @Test("A series-backed kind (BP) synthesizes rows the list can show when recent is empty")
    func seriesBackedKindYieldsRows() {
        // Precondition: the list only attempts the fallback for series-backed kinds.
        #expect(ChartDetailStore.kindSupportsSeries(.bloodPressure))
        // A non-empty series → non-empty synthesized rows → the list paints data
        // instead of the empty state, matching the chart.
        let points = [
            SeriesPoint(id: "bp-1", at: .now.addingTimeInterval(-86400), value: 122, secondary: 79),
            SeriesPoint(id: "bp-2", at: .now, value: 125, secondary: 81)
        ]
        let rows = ChartDetailStore.measurementsFromSeriesPoints(points, kind: .bloodPressure)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.kind == .bloodPressure })
    }

    @Test("A non-series kind is NOT attempted (honest empty state, no bad fetch)")
    func nonSeriesKindGatedOut() {
        // `bodyTemperature` is HK-write-only — the series route 422s it, so the
        // list's `kindSupportsSeries` guard short-circuits the fallback and shows
        // the honest empty state rather than firing a doomed series request.
        #expect(!ChartDetailStore.kindSupportsSeries(.bodyTemperature))
    }

    @Test("Empty series → empty rows → the list keeps its honest empty state")
    func emptySeriesKeepsEmptyState() {
        let rows = ChartDetailStore.measurementsFromSeriesPoints([], kind: .pulse)
        #expect(rows.isEmpty)
    }

    // MARK: - D2 drill-down count scope (v0.14.4)

    @Test("isOutsideRange is true only when data exists but falls outside the range")
    func dataStateOutsideRangeFlag() {
        let latest = Measurement(
            id: "x",
            kind: .activeEnergy,
            recordedAt: .now.addingTimeInterval(-86400 * 120),
            value: .scalar(480),
            source: .appleHealth
        )
        // Data exists, but every row is older than the selected window.
        #expect(MetricDataState.empty(reason: .outsideRange(latestAt: latest.recordedAt)).isOutsideRange)
        // Never-recorded: not "outside range" — the honest "No entries".
        #expect(!MetricDataState.empty(reason: .noData).isOutsideRange)
        // Populated in-range: not "outside range" either.
        #expect(!MetricDataState.ready(latest: latest, samples: [latest]).isOutsideRange)
    }
}
