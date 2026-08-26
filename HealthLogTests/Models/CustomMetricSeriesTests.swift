import Foundation
@testable import HealthLog
import Testing

/// **Pure derivations behind the custom-metric detail page.**
///
/// The load-bearing property across all of these: an entry WITHOUT a numeric
/// reading must never reach a derivation. A phantom `0` in the stats drags the
/// mean and min down and paints a dip-to-zero on the chart — the exact bug class
/// the labs surface shipped and had to unwind. Every helper filters first.
///
/// `@MainActor` because `chartPoints` returns `BiomarkerChart.DatedValue`, a type
/// nested in a `View`.
@MainActor
@Suite("Custom metric — series derivations")
struct CustomMetricSeriesTests {
    private static let metric = CustomMetricDTO(
        id: "cm-1", name: "Griffkraft", unit: "kg", targetLow: 40, targetHigh: 60
    )

    /// Build an entry `daysAgo` before a fixed reference instant.
    private static func entry(
        id: String,
        value: Double?,
        daysAgo: Int,
        now: Date = referenceNow
    ) -> CustomMetricEntryDTO {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return CustomMetricEntryDTO(
            id: id,
            customMetricId: "cm-1",
            value: value,
            unit: "kg",
            measuredAt: ISO8601DateFormatter.fractional.string(from: date)
        )
    }

    /// Fixed "now" so the window tests never straddle a real clock boundary.
    private static let referenceNow = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Windowing

    @Test("Windowing keeps only entries inside the selected range")
    func windowingFiltersByRange() {
        let entries = [
            Self.entry(id: "a", value: 50, daysAgo: 1),
            Self.entry(id: "b", value: 51, daysAgo: 10),
            Self.entry(id: "c", value: 52, daysAgo: 200)
        ]
        let week = CustomMetricSeries.windowed(entries, range: .week, now: Self.referenceNow)
        #expect(week.map(\.id) == ["a"])
        let month = CustomMetricSeries.windowed(entries, range: .month, now: Self.referenceNow)
        #expect(month.map(\.id) == ["a", "b"])
    }

    @Test("The .all range is a pass-through")
    func allRangePassesThrough() {
        let entries = [
            Self.entry(id: "a", value: 50, daysAgo: 1),
            Self.entry(id: "b", value: 51, daysAgo: 5000)
        ]
        #expect(CustomMetricSeries.windowed(entries, range: .all, now: Self.referenceNow).count == 2)
    }

    @Test("An entry with an unparseable timestamp is KEPT, never silently dropped")
    func unparseableTimestampIsKept() {
        // We never lose a logged value because of a malformed wire timestamp —
        // the user typed that number and must still see it.
        let broken = CustomMetricEntryDTO(
            id: "broken", customMetricId: "cm-1", value: 50, unit: "kg", measuredAt: "not-a-date"
        )
        let windowed = CustomMetricSeries.windowed([broken], range: .day, now: Self.referenceNow)
        #expect(windowed.map(\.id) == ["broken"])
    }

    // MARK: - Value-bearing filter

    @Test("valueBearing drops absent readings but keeps a genuine zero")
    func valueBearingFilter() {
        let entries = [
            Self.entry(id: "num", value: 50, daysAgo: 1),
            Self.entry(id: "zero", value: 0, daysAgo: 2),
            Self.entry(id: "absent", value: nil, daysAgo: 3)
        ]
        #expect(CustomMetricSeries.valueBearing(entries).map(\.id) == ["num", "zero"])
    }

    // MARK: - Stats

    @Test("Stats are computed over numeric readings only")
    func statsIgnoreAbsentReadings() {
        let entries = [
            Self.entry(id: "a", value: 40, daysAgo: 1),
            Self.entry(id: "b", value: 60, daysAgo: 2),
            Self.entry(id: "absent", value: nil, daysAgo: 3)
        ]
        let stats = CustomMetricSeries.stats(for: entries)
        #expect(stats?.count == 2, "the absent row must not be counted")
        #expect(stats?.min == 40, "an absent row must not drag min toward zero")
        #expect(stats?.max == 60)
        #expect(stats?.mean == 50)
    }

    @Test("Stats over an all-absent set are nil so the strip self-suppresses")
    func statsNilWhenNoNumbers() {
        let entries = [Self.entry(id: "absent", value: nil, daysAgo: 1)]
        #expect(CustomMetricSeries.stats(for: entries) == nil)
        #expect(CustomMetricSeries.stats(for: []) == nil)
    }

    @Test("Median over an even and an odd count")
    func medianComputation() {
        let odd = [
            Self.entry(id: "a", value: 10, daysAgo: 1),
            Self.entry(id: "b", value: 20, daysAgo: 2),
            Self.entry(id: "c", value: 90, daysAgo: 3)
        ]
        #expect(CustomMetricSeries.median(for: odd) == 20)

        let even = [
            Self.entry(id: "a", value: 10, daysAgo: 1),
            Self.entry(id: "b", value: 20, daysAgo: 2)
        ]
        #expect(CustomMetricSeries.median(for: even) == 15)
        #expect(CustomMetricSeries.median(for: []) == nil)
    }

    // MARK: - Chart points

    @Test("Chart points drop absent readings and unparseable timestamps")
    func chartPointsAreComplete() {
        let broken = CustomMetricEntryDTO(
            id: "broken", customMetricId: "cm-1", value: 50, unit: "kg", measuredAt: "not-a-date"
        )
        let entries = [
            Self.entry(id: "ok", value: 50, daysAgo: 1),
            Self.entry(id: "absent", value: nil, daysAgo: 2),
            broken
        ]
        let points = CustomMetricSeries.chartPoints(entries)
        #expect(points.map(\.id) == ["ok"], "a point needs both coordinates to be plottable")
    }

    // MARK: - In-band count

    @Test("In-band count reports numeric rows inside the target window")
    func inBandCounting() {
        let entries = [
            Self.entry(id: "in1", value: 50, daysAgo: 1),
            Self.entry(id: "in2", value: 40, daysAgo: 2),
            Self.entry(id: "out", value: 70, daysAgo: 3),
            Self.entry(id: "absent", value: nil, daysAgo: 4)
        ]
        let counts = CustomMetricSeries.inBandCount(entries, metric: Self.metric)
        #expect(counts?.inBand == 2)
        #expect(counts?.total == 3, "the absent row is excluded from both numerator and denominator")
    }

    @Test("In-band count is nil when the metric declares no target band")
    func inBandNilWithoutBand() {
        let bandless = CustomMetricDTO(id: "cm-2", name: "A", unit: "kg")
        let entries = [Self.entry(id: "a", value: 50, daysAgo: 1)]
        #expect(CustomMetricSeries.inBandCount(entries, metric: bandless) == nil)
    }

    @Test("In-band count is nil when no entry carries a number")
    func inBandNilWithoutNumbers() {
        let entries = [Self.entry(id: "absent", value: nil, daysAgo: 1)]
        #expect(CustomMetricSeries.inBandCount(entries, metric: Self.metric) == nil)
        #expect(CustomMetricSeries.inBandCount([], metric: Self.metric) == nil)
    }
}
