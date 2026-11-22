import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The chart and metric page changes of E-P2 part A: the day curves scrub on
/// a time axis, the sleep composition follows the page range, trend arrows
/// point straight, and the statistic raster stacks blood pressure rows.
@MainActor
@Suite("E-P2 A charts and metric page")
struct EP2AChartsTests {
    // MARK: - Intraday pulse on a time axis

    @Test("a minute of the day maps to the anchor day and back")
    func intradayMinuteRoundTrip() {
        for minute in [0, 10, 359, 720, 1439, 1440] {
            let date = IntradayPulseChartView.date(forMinute: minute)
            #expect(IntradayPulseChartView.minute(of: date) == minute)
        }
        #expect(IntradayPulseChartView.date(forMinute: 60).timeIntervalSince(IntradayPulseChartView.anchor) == 3600)
    }

    @Test("scrubbing the day curve snaps to the nearest bucket")
    func intradayScrubSnaps() throws {
        let series = [
            IntradayPulseDTO.Bucket(startMinute: 480, mean: 62, count: 4),
            IntradayPulseDTO.Bucket(startMinute: 490, mean: 70, count: 3),
            IntradayPulseDTO.Bucket(startMinute: 600, mean: 58, count: 5)
        ]
        let touched = IntradayPulseChartView.date(forMinute: 493)
        let nearest = try #require(HLChartScrubber.nearest(to: touched, in: series, date: \.scrubDate))
        #expect(nearest.startMinute == 490)
    }

    // MARK: - Same-time baseline on a time axis

    @Test("an hour maps to the anchor day and back, and labels as a clock time")
    func sameTimeHours() {
        for hour in [0, 9, 23] {
            #expect(SameTimeBaselineBlock.hour(of: SameTimeBaselineBlock.date(forHour: hour)) == hour)
        }
        #expect(SameTimeBaseline.Point(hour: 9, today: 1, typical: 2).scrubDate == SameTimeBaselineBlock.date(forHour: 9))
        #expect(SameTimeBaselineBlock.hourLabel(9) == IntradayPulseMath.minuteLabel(540))
    }

    @Test("a whole figure keeps no decimals, a half step keeps one")
    func sameTimeFractionDigits() {
        #expect(SameTimeBaselineBlock.fractionDigits(4200) == 0 ... 0)
        #expect(SameTimeBaselineBlock.fractionDigits(4200.5) == 1 ... 1)
    }

    // MARK: - Sleep composition follows the page range

    @Test("the composition shows the page range's nights, at most the server's 30")
    func sleepCompositionNightCount() {
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 1) == 1)
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 7) == 7)
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 30) == 30)
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 180) == 30)
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 3650) == 30)
        #expect(SleepStageCompositionCard.nightCount(forRangeDays: 0) == 1)
    }

    @Test("the minutes axis of the composition reads in whole hours")
    func sleepCompositionHours() {
        #expect(SleepStageCompositionCard.hoursLabel(480) == "8")
        #expect(SleepStageCompositionCard.hoursLabel(90) == "1")
    }

    // MARK: - Trend chips

    @Test("the hero delta badge takes its arrow from the sign and stays grey whatever the verdict")
    func heroDeltaBadge() {
        #expect(HeroDeltaChip.symbol(for: 1.2) == "arrow.up")
        #expect(HeroDeltaChip.symbol(for: -0.4) == "arrow.down")
        #expect(HeroDeltaChip.symbol(for: 0) == "minus")
        #expect(HeroDeltaChip.tone(for: nil) == .neutral)
        #expect(HeroDeltaChip.tone(for: .positive) == .success)
        #expect(HeroDeltaChip.tone(for: .negative) == .critical)
        #expect(HeroDeltaChip.tone(for: .neutral) == .neutral)
    }

    // MARK: - Metric chart scrub

    @Test("the scrub callout gets the canonical point behind a converted one")
    func canonicalPointForCallout() {
        let canonical = [
            SeriesPoint(id: "a", at: Date(timeIntervalSince1970: 0), value: 80, secondary: nil),
            SeriesPoint(id: "b", at: Date(timeIntervalSince1970: 86400), value: 81, secondary: nil)
        ]
        let plotted = SeriesPoint(id: "b", at: Date(timeIntervalSince1970: 86400), value: 178.6, secondary: nil)
        #expect(ChartCard.canonicalPoint(for: plotted, in: canonical).value == 81)
        let stray = SeriesPoint(id: "z", at: .now, value: 5, secondary: nil)
        #expect(ChartCard.canonicalPoint(for: stray, in: canonical).value == 5)
    }

    // MARK: - Statistic raster

    @Test("a stats row gives its cells for a stacked raster, none without stats")
    func statsRowCells() {
        let stats = SeriesStats(mean: 128, min: 112, max: 141, stdDev: 6, count: 30)
        let row = StatsRow(stats: stats, median: 127, unit: "mmHg")
        #expect(row.cells.map(\.value) == ["112", "128", "141", "127"])
        #expect(row.cells.allSatisfy { $0.unit == "mmHg" })
        #expect(StatsRow(stats: nil, median: nil, unit: "mmHg").cells.isEmpty)
    }

    // MARK: - Lab overlay

    @Test("the lab marker chart has the regular chart height")
    func labOverlayHeight() {
        #expect(ChartLabOverlay.chartHeight == HLChartStyle.heightRegular)
    }
}
