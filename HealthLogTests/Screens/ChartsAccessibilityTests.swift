import Accessibility
import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Regression coverage for the C3 (empty time-axis ticks) and C4 (BP secondary
/// line invisible to VoiceOver) audit findings.
///
/// We don't render a SwiftUI view here — `ChartsAccessibility.makeDescriptor`
/// is a pure function on data + metric kind, so the descriptor is testable in
/// isolation.
@Suite("ChartsAccessibility descriptor")
struct ChartsAccessibilityTests {
    // MARK: - Fixtures

    private static func point(
        idx: Int,
        value: Double,
        secondary: Double? = nil,
        startingAt start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SeriesPoint {
        // 1 day apart so the formatter actually has distinct dates to render.
        let at = start.addingTimeInterval(TimeInterval(idx * 86400))
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: secondary)
    }

    private static func bpSeries(count: Int = 5) -> MeasurementSeries {
        let pts = (0 ..< count).map { i in
            point(idx: i, value: 120 + Double(i), secondary: 80 + Double(i))
        }
        let stats = SeriesStats(mean: 122, min: 80, max: 124, stdDev: 10, count: count)
        return MeasurementSeries(kind: .bloodPressure, points: pts, stats: stats)
    }

    private static func weightSeries(count: Int = 5) -> MeasurementSeries {
        let pts = (0 ..< count).map { i in point(idx: i, value: 72.0 + Double(i) * 0.1) }
        let stats = SeriesStats(mean: 72.2, min: 72.0, max: 72.4, stdDev: 0.1, count: count)
        return MeasurementSeries(kind: .weight, points: pts, stats: stats)
    }

    // MARK: - C3 — time-axis ticks must not be empty

    @Test("X-axis returns a non-empty localized date for every valid index")
    func timeAxisLabelsAreNotEmpty() throws {
        let series = Self.weightSeries(count: 5)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .weight)

        // `xAxis` is exposed as the protocol `any AXDataAxisDescriptor`; cast to
        // the concrete numeric variant we built so we can drive its provider.
        let xAxis = try #require(descriptor.xAxis as? AXNumericDataAxisDescriptor)
        for idx in 0 ..< series.points.count {
            let label = xAxis.valueDescriptionProvider(Double(idx))
            #expect(!label.isEmpty, "tick \(idx) returned empty label — VoiceOver would announce '(empty)'")
        }
    }

    @Test("X-axis returns empty string for out-of-range indices (no crash)")
    func timeAxisLabelsToleratesOutOfRange() throws {
        let series = Self.weightSeries(count: 3)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .weight)
        let xAxis = try #require(descriptor.xAxis as? AXNumericDataAxisDescriptor)

        // 99 is well past the data — provider must not crash, just return empty.
        let label = xAxis.valueDescriptionProvider(99)
        #expect(label.isEmpty)
    }

    // MARK: - C4 — BP must expose BOTH systolic AND diastolic series

    @Test("Blood pressure exposes two accessible series (systolic + diastolic)")
    func bloodPressureHasTwoSeries() {
        let series = Self.bpSeries(count: 4)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .bloodPressure)

        #expect(descriptor.series.count == 2, "BP must expose systolic + diastolic")

        let names = Set(descriptor.series.map(\.name))
        #expect(names.contains(String(localized: "Systolic")))
        #expect(names.contains(String(localized: "Diastolic")))
    }

    @Test("Diastolic series carries one data point per source point")
    func diastolicSeriesHoldsSecondaryValues() throws {
        let series = Self.bpSeries(count: 3)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .bloodPressure)

        let diastolic = try #require(
            descriptor.series.first(where: { $0.name == String(localized: "Diastolic") })
        )
        // We can't read raw doubles back out of `AXDataPoint` without going through
        // `AXDataPointValue` enum extraction; covering count + presence is sufficient
        // to prove the secondary line is exposed (the values plumb through directly
        // from `point.secondary` by construction).
        #expect(diastolic.dataPoints.count == 3)
    }

    @Test("Systolic and diastolic series have distinct names")
    func bpSeriesNamesAreDistinct() {
        let series = Self.bpSeries(count: 3)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .bloodPressure)
        let names = descriptor.series.map(\.name)
        #expect(Set(names).count == names.count, "series names must be unique for VoiceOver rotor")
    }

    // MARK: - Single-series metrics still work

    @Test("Non-BP metrics expose exactly one series with the metric's display name")
    func singleSeriesMetric() {
        let series = Self.weightSeries(count: 4)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .weight)

        #expect(descriptor.series.count == 1)
        #expect(descriptor.series.first?.name == MetricKind.weight.displayName)
    }

    @Test("BP without secondary values falls back to a single series (no crash)")
    func bpWithoutSecondaryFallsBackToSingleSeries() {
        // Guard: if the API ever ships BP rows without a diastolic, we shouldn't crash
        // and shouldn't emit an empty 'Diastolisch' series — just one series like the others.
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 120.0 + Double($0)) }
        let stats = SeriesStats(mean: 121, min: 120, max: 122, stdDev: 1, count: 3)
        let series = MeasurementSeries(kind: .bloodPressure, points: pts, stats: stats)

        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .bloodPressure)
        #expect(descriptor.series.count == 1)
    }

    // MARK: - Title + summary smoke

    @Test("Descriptor has a non-empty title and summary")
    func titleAndSummaryArePopulated() throws {
        let series = Self.weightSeries(count: 5)
        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .weight)

        let title = try #require(descriptor.title)
        let summary = try #require(descriptor.summary)
        #expect(!title.isEmpty)
        #expect(!summary.isEmpty)
    }

    // MARK: - Y-axis range stays valid for degenerate data

    @Test("Y-axis range stays valid when min == max (single value)")
    func yAxisRangeWidensForFlatSeries() throws {
        let pts = [Self.point(idx: 0, value: 72.0)]
        let stats = SeriesStats(mean: 72, min: 72, max: 72, stdDev: 0, count: 1)
        let series = MeasurementSeries(kind: .weight, points: pts, stats: stats)

        let descriptor = ChartsAccessibility.makeDescriptor(for: series, kind: .weight)
        // Quirk: `xAxis` is `any AXDataAxisDescriptor` (protocol) but `yAxis` is the
        // concrete `AXNumericDataAxisDescriptor?` already — only need to unwrap.
        let yAxis = try #require(descriptor.yAxis)
        #expect(yAxis.range.lowerBound < yAxis.range.upperBound)
    }

    // MARK: - selectedPointAnnouncement (chart detail screen, A3 §5.2)

    @Test("Selected-point announcement reads the value with the unit")
    func announcementContainsValueAndUnit() {
        let point = SeriesPoint(id: "p", at: Date(timeIntervalSince1970: 1_700_000_000), value: 72.4, secondary: nil)
        let announcement = ChartsAccessibility.selectedPointAnnouncement(point: point, kind: .weight)
        // Locale-dependent decimal separator — accept both forms.
        #expect(announcement.contains("72,4") || announcement.contains("72.4"))
        #expect(announcement.contains("kg"))
    }

    @Test("BP selected-point announcement reads systolic AND diastolic")
    func announcementBP() {
        let point = SeriesPoint(id: "p", at: Date(timeIntervalSince1970: 1_700_000_000), value: 128, secondary: 82)
        let announcement = ChartsAccessibility.selectedPointAnnouncement(point: point, kind: .bloodPressure)
        // Both values surface — order matters less than presence.
        #expect(announcement.contains("128"))
        #expect(announcement.contains("82"))
        #expect(announcement.contains("mmHg"))
    }

    @Test("Selected-point announcement contains a date phrase")
    func announcementDate() {
        let point = SeriesPoint(id: "p", at: Date(timeIntervalSince1970: 1_700_000_000), value: 72.4, secondary: nil)
        let announcement = ChartsAccessibility.selectedPointAnnouncement(point: point, kind: .weight)
        // Should include a colon separating date from value.
        #expect(announcement.contains(":"))
    }
}
