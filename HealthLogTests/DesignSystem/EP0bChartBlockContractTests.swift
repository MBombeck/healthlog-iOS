import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The chart blocks every detail page shares: the scrub callout, the value
/// axis, the reference lines and bands, the sparkline tint, the statistic
/// raster and the period set.
@MainActor
@Suite("E-P0b chart blocks")
struct EP0bChartBlockContractTests {
    // MARK: - Scrubber and callout

    @Test("the scrub callout speaks date, value, unit and the record note")
    func calloutSpeech() {
        #expect(HLScrubCallout.spokenText(title: "Mo., 3. Nov.", value: "61", unit: "bpm", marksRecord: false)
            == "Mo., 3. Nov., 61 bpm")
        #expect(HLScrubCallout.spokenText(title: "Mo.", value: "4", unit: nil, marksRecord: false) == "Mo., 4")
        let record = HLScrubCallout.spokenText(title: "Mo.", value: "61", unit: "bpm", marksRecord: true)
        #expect(record == "Mo., 61 bpm, " + String(localized: "Personal best"))
    }

    @Test("the emphasised scrub dot is larger than any series symbol")
    func selectionDot() {
        #expect(HLChartScrubber.selectionSymbolSize == 120)
        #expect(HLScrubCallout.maxWidth == 220)
    }

    @Test("the metric callout formats one value and a blood pressure through the account formatter")
    func seriesPointCallout() {
        let units = UnitPreferences.standard
        let single = SeriesPoint(id: "a", at: .now, value: 61, secondary: nil)
        #expect(HLSeriesPointCallout.value(of: single, kind: .pulse, units: units)
            == MetricValueFormatter.formatScalar(61, kind: .pulse, units: units, glucose: .seriesPreConvertedGlucose))
        let pressure = SeriesPoint(id: "b", at: .now, value: 128, secondary: 82)
        #expect(HLSeriesPointCallout.value(of: pressure, kind: .bloodPressure, units: units)
            == MetricValueFormatter.formatBloodPressure(systolic: 128, diastolic: 82, units: units))
        #expect(!HLSeriesPointCallout.title(for: .now).isEmpty)
    }

    @Test("the old callout name is the design system's callout")
    func calloutAlias() {
        #expect(SelectedPointCallout.self == HLSeriesPointCallout.self)
    }

    // MARK: - Axes

    @Test("value labels read through the number helper unless the chart names words")
    func valueLabels() {
        #expect(HLChartAxis.valueLabel(nil, label: nil).isEmpty)
        #expect(HLChartAxis.valueLabel(60, label: nil) == HLValueFormat.number(60, fractionDigits: 0 ... 1))
        #expect(HLChartAxis.valueLabel(2, label: { $0 > 1 ? "Super" : "Lausig" }) == "Super")
    }

    @Test("the date axis kept its rule after the move into the design system")
    func dateAxisAlias() {
        #expect(ChartDateAxis.self == HLChartDateAxis.self)
        #expect(HLChartDateAxis.step(forSpan: 30 * 86400) == .init(component: .weekOfYear, value: 1))
    }

    // MARK: - Reference lines and bands

    @Test("a band is its two edges, the label on the upper one")
    func bandEdges() {
        let band = HLChartReferenceLines.band(lower: 50, upper: 60, label: "Ziel", unit: "bpm")
        #expect(band.lines.map(\.kind) == [.lower, .upper])
        #expect(band.lines.map(\.value) == [50, 60])
        #expect(band.lines.map(\.label) == ["", "Ziel"])
        #expect(band.values == [50, 60])
        #expect(band.lines.allSatisfy { HLReferenceLineStyle(line: $0).isDashed }, "a clinical band is dashed")
    }

    @Test("an open band draws its one edge with the label; a non-finite edge draws nothing")
    func openBand() {
        let below = HLChartReferenceLines.band(lower: nil, upper: 5.7, label: "Grenze", unit: "%")
        #expect(below.lines.map(\.kind) == [.upper])
        let above = HLChartReferenceLines.band(lower: 30, upper: nil, label: "Grenze", unit: "ng/ml")
        #expect(above.lines.map(\.label) == ["Grenze"])
        #expect(HLChartReferenceLines.band(lower: .nan, upper: .infinity, unit: "").lines.isEmpty)
        #expect(HLChartReferenceLines.none.lines.isEmpty)
    }

    @Test("a personal band is solid, tinted by edge")
    func personalBand() {
        let band = HLChartReferenceLines.band(lower: 70, upper: 74, source: .personal, unit: "kg")
        let styles = band.lines.map(HLReferenceLineStyle.init(line:))
        #expect(styles.map(\.isDashed) == [false, false])
        #expect(styles.map(\.tintRole) == [.lower, .upper])
    }

    @Test("the old reference line names are the design system's")
    func referenceAliases() {
        #expect(ReferenceLineMarks.self == HLChartReferenceLines.self)
        #expect(ReferenceLineStyle.self == HLReferenceLineStyle.self)
    }

    // MARK: - Sparkline

    @Test("every sparkline has one tint")
    func sparklineTint() {
        #expect(HLSparkline.defaultTint == HLChartTints.seriesMid)
    }

    // MARK: - In-target rail

    @Test("the rail headed by the share names the window and clamps")
    func railShare() {
        let row = RangeBandRow(share: 131, window: "90 T")
        #expect(row.pct == 100)
        #expect(row.title == String(localized: "In range") + " (90 T)")
        #expect(row.spokenText == String(localized: "\(100) percent of measurements in range over \("90 T")"))
        let bare = RangeBandRow(share: -4)
        #expect(bare.pct == 0)
        #expect(bare.title == String(localized: "In range"))
    }

    @Test("the rail headed by the band keeps the band's line")
    func railBand() {
        let band = RangeBand(lowerLabel: "71", upperLabel: "74", unit: "kg", pctInRange: 62)
        let row = RangeBandRow(band: band)
        #expect(row.title == band.targetLine)
        #expect(row.pct == 62)
        #expect(HLRangeBandMetrics.railHeight == 8)
        #expect(HLRangeBandMetrics.cornerRadius == 4)
    }

    // MARK: - Statistic raster

    @Test("the stats row hands its four figures to the raster")
    func statGrid() {
        let stats = SeriesStats(mean: 58.4, min: 52, max: 66, stdDev: 3, count: 30)
        let boxes = StatsRow.boxes(stats: stats, median: 58) { HLValueFormat.number($0, fractionDigits: 0 ... 1) }
        #expect(boxes.map(\.label) == [
            String(localized: "Min"), String(localized: "chart.stat.mean"),
            String(localized: "Max"), String(localized: "chart.stat.median")
        ])
        #expect(StatBox.self == HLStatTile.self)
        #expect(HLStatGrid.stacks(.accessibility1))
        #expect(!HLStatGrid.stacks(.xxxLarge))
        #expect(HLStatTile.spokenText(HLStatCell(label: "Min", value: "52", unit: "bpm")) == "Min 52 bpm")
        #expect(HLStatTile.spokenText(HLStatCell(label: "Einträge", value: "12", unit: nil)) == "Einträge 12")
    }

    @Test("several raster rows keep their headings and order")
    func statSections() {
        let grid = HLStatGrid(sections: [
            .init(title: "Systolisch", cells: [HLStatCell(label: "Min", value: "112")]),
            .init(title: "Diastolisch", cells: [HLStatCell(label: "Min", value: "71")])
        ])
        #expect(grid.sections.map(\.title) == ["Systolisch", "Diastolisch"])
        #expect(HLStatGrid(cells: []).sections.count == 1)
    }

    // MARK: - Period set

    @Test("the one period set is T, W, M, 6M, J, Alle in days")
    func periodSet() {
        #expect(HLTimeRange.allCases.map(\.days) == [1, 7, 30, 180, 365, 3650])
        #expect(HLTimeRange.standard == .month)
        #expect(HLTimeRange(days: 180) == .sixMonths)
        #expect(HLTimeRange(days: 90) == nil)
        for range in HLTimeRange.allCases {
            #expect(!range.label.isEmpty)
            #expect(!range.rangeAccessibilityLabel.isEmpty)
        }
    }

    @Test("the period set speaks like the metric page's")
    func periodSetMatchesMetricPage() {
        let metric = ChartDetailStore.Range.allCases
        #expect(metric.map(\.rawValue) == HLTimeRange.allCases.map(\.rawValue))
        #expect(metric.map(\.label) == HLTimeRange.allCases.map(\.label))
        #expect(metric.map(\.rangeAccessibilityLabel) == HLTimeRange.allCases.map(\.rangeAccessibilityLabel))
    }

    @Test("a window starts that many calendar days back, all has no start")
    func periodStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9)))
        let week = try #require(HLTimeRange.week.start(endingAt: now, calendar: calendar))
        #expect(week == calendar.date(from: DateComponents(year: 2026, month: 11, day: 8)))
        #expect(HLTimeRange.day.start(endingAt: now, calendar: calendar) == calendar.startOfDay(for: now))
        #expect(HLTimeRange.all.start(endingAt: now, calendar: calendar) == nil)
    }
}
