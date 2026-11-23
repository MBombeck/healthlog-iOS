import Foundation
@testable import HealthLog
import Testing

/// The metric page's head, table, bands and durations as pure rules.
@Suite("F9C metric page")
@MainActor
struct F9CMetricPageTests {
    // MARK: - Period summary

    @Test("the summary of a blood pressure writes the pair")
    func pressurePair() {
        let value = MetricPeriodSummary.Model.value(mean: 122.4, diastolicMean: 78.2, kind: .bloodPressure, units: .standard)
        #expect(value == "122/78")
    }

    @Test("the summary of sleep is hours and minutes")
    func sleepDuration() {
        let value = MetricPeriodSummary.Model.value(mean: 7.2, diastolicMean: nil, kind: .sleep, units: .standard)
        #expect(value == MetricDurationFormat.text(hours: 7.2))
    }

    @Test("the period names both ends and drops the year inside the current one")
    func periodWithinYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12)))
        let text = MetricPeriodSummary.Model.period(start ... end, calendar: calendar, now: end)
        #expect(text.contains(start.formatted(.dateTime.day().month(.abbreviated))))
        #expect(text.contains(end.formatted(.dateTime.day().month(.abbreviated))))
        #expect(!text.contains("2026"))
    }

    @Test("a period across two years shows the years")
    func periodAcrossYears() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let start = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 1, hour: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12)))
        let text = MetricPeriodSummary.Model.period(start ... end, calendar: calendar, now: end)
        #expect(text.contains("2025"))
        #expect(text.contains("2026"))
    }

    // MARK: - Statistics table

    @Test("the table takes its column titles and unit from the cells")
    func tableHeader() {
        let rows = [
            MetricStatsTable.Row(title: "Sys", cells: [
                HLStatCell(label: "Min", value: "110", unit: "mmHg"),
                HLStatCell(label: "Ø", value: "122", unit: "mmHg")
            ]),
            MetricStatsTable.Row(title: "Dia", cells: [
                HLStatCell(label: "Min", value: "70", unit: "mmHg"),
                HLStatCell(label: "Ø", value: "78", unit: "mmHg")
            ])
        ]
        #expect(MetricStatsTable.columnTitles(rows) == ["Min", "Ø"])
        #expect(MetricStatsTable.unit(rows) == "mmHg")
        #expect(MetricStatsTable.spoken(rows[0]) == "Sys, Min 110 mmHg, Ø 122 mmHg")
    }

    @Test("a table without rows has no header")
    func emptyTable() {
        #expect(MetricStatsTable.columnTitles([]).isEmpty)
        #expect(MetricStatsTable.unit([]).isEmpty)
    }

    // MARK: - Chart height

    @Test(
        "the chart grows only where the page's column is wide",
        arguments: zip(
            [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376] as [CGFloat],
            [false, false, false, false, false, true, true, true, true, true]
        )
    )
    func heightPerWindow(window: CGFloat, grows: Bool) {
        // The card spans the readable column of the page.
        let card = min(HLLayout.readableWidth, window - 2 * HLLayout.pageMargin)
        let height = MetricChartHeight.height(visibleHeight: 1200, width: card)
        #expect(height == (grows ? 480 : HLChartStyle.heightRegular))
    }

    @Test("the threshold is the side-by-side width less the margins")
    func heightThreshold() {
        let edge = HLLayout.sideBySideMinimum - 2 * HLLayout.pageMargin
        #expect(MetricChartHeight.height(visibleHeight: 1200, width: edge - 1) == HLChartStyle.heightRegular)
        #expect(MetricChartHeight.height(visibleHeight: 1200, width: edge) == 480)
        // Never below the regular height.
        #expect(MetricChartHeight.height(visibleHeight: 300, width: 720) == HLChartStyle.heightRegular)
    }

    // MARK: - Target band

    @Test("a lower and an upper line of one series make a band")
    func bandsFromLines() {
        let lines = [
            SeriesReferenceLine(value: 90, kind: .lower, source: .personal, appliesTo: .value, label: "low"),
            SeriesReferenceLine(value: 135, kind: .upper, source: .personal, appliesTo: .value, label: "high"),
            SeriesReferenceLine(value: 85, kind: .upper, source: .personal, appliesTo: .secondary, label: "dia")
        ]
        let bands = MetricTargetBand.bands(from: lines)
        #expect(bands == [MetricTargetBand(lower: 90, upper: 135, appliesTo: .value)])
    }

    @Test("crossed edges make no band")
    func crossedEdges() {
        let lines = [
            SeriesReferenceLine(value: 140, kind: .lower, source: .clinical, label: "low"),
            SeriesReferenceLine(value: 100, kind: .upper, source: .clinical, label: "high")
        ]
        #expect(MetricTargetBand.bands(from: lines).isEmpty)
    }

    @Test("spot measurements show their points, continuous ones a line")
    func measuredPoints() {
        #expect(MetricKind.bloodPressure.showsMeasuredPoints)
        #expect(MetricKind.glucose.showsMeasuredPoints)
        #expect(!MetricKind.weight.showsMeasuredPoints)
    }

    // MARK: - Durations

    @Test("a duration cell names hours and minutes in the head's words")
    func durationCell() {
        let german = Locale(identifier: "de_DE")
        #expect(MetricDurationFormat.cell(hours: 7.2167, locale: german) == "7 Std.\n13 Min.")
        #expect(MetricDurationFormat.cell(hours: 6.1, locale: german) == "6 Std.\n6 Min.")
        #expect(MetricDurationFormat.cell(hours: 8, locale: german) == "8 Std.")
        #expect(MetricDurationFormat.cell(64, kind: .pulse) == nil)
        #expect(MetricDurationFormat.cellUnit("h", kind: .sleep).isEmpty)
        #expect(MetricDurationFormat.cellUnit("kg", kind: .weight) == "kg")
    }

    @Test("the sleep axis spans whole hours, at least three")
    func hourDomain() {
        let domain = MetricDurationFormat.hourDomain(values: [6.8, 7.6])
        #expect(domain.upperBound - domain.lowerBound >= MetricDurationFormat.minimumHourSpan)
        #expect(domain.lowerBound == domain.lowerBound.rounded())
        #expect(domain.upperBound == domain.upperBound.rounded())
        #expect(domain.lowerBound <= 6.8)
        #expect(domain.upperBound >= 7.6)
        #expect(MetricDurationFormat.hourDomain(values: [0.5, 1]).lowerBound == 0)
        #expect(MetricDurationFormat.axisLabel(hours: 7) == "7")
    }

    // MARK: - Hero change

    @Test("a blood pressure change names the systolic value")
    func pressureChangeLabel() {
        let label = HeroDeltaChip.label(delta: 0.9, unit: "mmHg", kind: .bloodPressure)
        let plain = HeroDeltaChip.label(delta: 0.9, unit: "mmHg", kind: nil)
        #expect(label == String(localized: "chart.hero.change.systolic \(plain)"))
        #expect(label != plain)
        #expect(HeroDeltaChip.label(delta: -1, unit: "kg", kind: .weight).hasSuffix("kg"))
    }
}

/// The value axis keeps a calm series calm.
@Suite("F9C value axis span")
@MainActor
struct F9CValueAxisSpanTests {
    @Test("a weight that moves little stands on at least four kilograms")
    func weightSpan() {
        let domain = MetricChartScale.widened(72 ... 74, toSpan: MetricChartScale.minimumSpan(for: .weight, unit: "kg"))
        #expect(domain.upperBound - domain.lowerBound >= 4)
        #expect(domain.lowerBound <= 72 && domain.upperBound >= 74)
    }

    @Test("oxygen never reads past 100 percent")
    func oxygenCap() {
        let domain = MetricChartScale.widened(96 ... 99, toSpan: 10, capsAtHundred: true)
        #expect(domain.upperBound == 100)
        #expect(domain.lowerBound == 90)
    }

    @Test("card and full screen share one value domain rule")
    func sharedDomain() {
        let weight = [SeriesPoint(id: "a", at: .now, value: 72, secondary: nil), SeriesPoint(id: "b", at: .now, value: 74, secondary: nil)]
        let domain = MetricChartScale.valueDomain(points: weight, references: [], kind: .weight, unit: "kg", useLog: false)
        #expect(domain.upperBound - domain.lowerBound >= 4)
        let sleep = [SeriesPoint(id: "c", at: .now, value: 6.8, secondary: nil), SeriesPoint(id: "d", at: .now, value: 7.6, secondary: nil)]
        #expect(MetricChartScale.valueDomain(points: sleep, references: [], kind: .sleep, unit: "h", useLog: false)
            == MetricDurationFormat.hourDomain(values: [6.8, 7.6]))
    }

    @Test("a wide series keeps its own axis")
    func wideSeries() {
        #expect(MetricChartScale.widened(60 ... 120, toSpan: 20) == 60 ... 120)
        #expect(MetricChartScale.minimumSpan(for: .weight, unit: "lb") == nil)
        #expect(MetricChartScale.minimumSpan(for: .steps, unit: "") == nil)
    }
}
