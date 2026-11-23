// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// The mood page in the shape of every detail page: the section order, the
/// full period set, the statistic raster, the chart axis, the trend arrow and
/// the one-line entry row, each read as data.
@Suite("E-P3 mood: page order, period set and row forms")
struct EP3MoodPresentationTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func entry(daysAgo: Int) -> MoodEntry {
        let day = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: now))!
        return MoodEntry(id: "e\(daysAgo)", recordedAt: day.addingTimeInterval(12 * 3600), score: 3)
    }

    // MARK: - Section order

    @Test("the analysis follows the detail-page order: figure, statistic, chart, deeper blocks, entries")
    func sectionOrder() {
        #expect(MoodAnalysisSection.order(hasPatterns: true, showsRecent: true) == [
            .hero, .stability, .trend, .heatmap, .tags, .patterns, .recent
        ])
    }

    @Test("a missing section moves the next one up")
    func missingSectionsCloseTheGap() {
        #expect(MoodAnalysisSection.order(hasPatterns: false, showsRecent: true) == [
            .hero, .stability, .trend, .heatmap, .tags, .recent
        ])
        #expect(MoodAnalysisSection.order(hasPatterns: false, showsRecent: false) == [
            .hero, .stability, .trend, .heatmap, .tags
        ])
        #expect(MoodAnalysisSection.recentIndex(hasPatterns: false) == 5)
        #expect(MoodAnalysisSection.recentIndex(hasPatterns: true) == 6)
    }

    // MARK: - Period set

    @Test("the mood page offers the full option set of every detail page")
    func fullPeriodSet() {
        #expect(MoodPeriod.allCases == [.day, .week, .month, .sixMonths, .year, .all])
        for period in MoodPeriod.allCases {
            #expect(!MoodAnalysisSection.windowLabel(for: period).isEmpty)
        }
    }

    @Test("each period cuts the history at its own window, the whole history at 3650 days")
    func periodWindows() {
        let entries = [0, 5, 20, 100, 300, 3000, 4000].map { Self.entry(daysAgo: $0) }
        func count(_ period: MoodPeriod) -> Int {
            period.filter(entries, now: Self.now, calendar: Self.utc).count
        }
        #expect(count(.week) == 2)
        #expect(count(.month) == 3)
        #expect(count(.sixMonths) == 4)
        #expect(count(.year) == 5)
        #expect(count(.all) == 6)
    }

    // MARK: - Calendar

    @Test("the calendar follows the page period: weeks up to six months, pixels for the year and all")
    func calendarFollowsPeriod() {
        #expect(MoodHeatmapSection.mode(forPeriod: .month) == .twelveWeeks)
        #expect(MoodHeatmapSection.mode(forPeriod: .sixMonths) == .twelveWeeks)
        #expect(MoodHeatmapSection.mode(forPeriod: .year) == .year)
        #expect(MoodHeatmapSection.mode(forPeriod: .all) == .year)
        #expect(MoodHeatmapSection.mode(forPeriod: nil) == .twelveWeeks)
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: .week) == 1)
        #expect(MoodHeatmapSection.compactWeeks(forPeriod: .all) == 12)
    }

    // MARK: - Statistic raster

    @Test("stability and entries stand as two cells of the statistic raster")
    func statisticCells() {
        let stability = MoodStability(score: 72, stdDev: 0.7, band: .steady, days: 30)
        let cells = MoodStabilitySection.cells(stability: stability, entryCount: 14, windowLabel: "in 30 days")
        #expect(cells.map(\.label) == [String(localized: "Stability"), String(localized: "Entries")])
        #expect(cells.first?.value == HLValueFormat.number(72, fractionDigits: 0 ... 0))
        #expect(cells.first?.unit == MoodStabilitySection.bandLabel(for: .steady))
        #expect(cells.last?.unit == "in 30 days")
    }

    @Test("a figure the period does not have is left out, never shown as zero")
    func statisticCellsOmitMissing() {
        #expect(MoodStabilitySection.cells(stability: nil, entryCount: 3, windowLabel: "w").count == 1)
        #expect(MoodStabilitySection.cells(stability: nil, entryCount: 0, windowLabel: "w").isEmpty)
    }

    // MARK: - Chart

    @Test("the value axis names the odd levels only, so three words fit beside the plot")
    func axisLabels() {
        #expect(MoodTrendChart.axisLabel(1) == MoodCopy.scoreLabel(1))
        #expect(MoodTrendChart.axisLabel(3) == MoodCopy.scoreLabel(3))
        #expect(MoodTrendChart.axisLabel(5) == MoodCopy.scoreLabel(5))
        #expect(MoodTrendChart.axisLabel(2).isEmpty)
        #expect(MoodTrendChart.axisLabel(4).isEmpty)
        #expect(MoodTrendChart.axisLabel(0).isEmpty)
        #expect(MoodTrendChart.meanLabel(3.4).contains(HLValueFormat.number(3.4, fractionDigits: 1 ... 1)))
    }

    // MARK: - Trend arrow

    @Test("the trend arrow points straight up or down, never diagonally")
    func trendArrows() {
        #expect(MoodHeroSummary.symbol(for: .up) == "arrow.up")
        #expect(MoodHeroSummary.symbol(for: .down) == "arrow.down")
        #expect(MoodHeroSummary.symbol(for: .stable) == "minus")
        #expect(MoodHeroSummary.symbol(for: nil) == nil)
    }

    // MARK: - Entry row

    @Test("the entry row says when, what was rated and tagged, then the note, on one line")
    func entryRowDetail() {
        let parts = MoodEntryRow.detailParts(
            when: "vor 2 Std.",
            rated: ["Arbeit: gut"],
            tags: ["Sport"],
            freeTags: ["Regen", "note:hidden"],
            note: "Langer Tag\nmit Wind"
        )
        #expect(HLRowDetail.joined(parts) == "vor 2 Std., Arbeit: gut, Sport, Regen, Langer Tag mit Wind")
    }

    @Test("an entry without tags or note shows only when it was logged")
    func entryRowDetailMinimal() {
        let parts = MoodEntryRow.detailParts(when: "gestern", rated: [], tags: [], freeTags: [], note: nil)
        #expect(HLRowDetail.joined(parts) == "gestern")
    }

    // MARK: - Tag badges

    @Test("a tag badge carries the tag and its signed swing, the arrow gives the direction")
    func tagBadge() {
        let up = MoodTagDelta(tag: "Sport", average: 4.2, delta: 0.7, count: 5)
        let down = MoodTagDelta(tag: "Regen", average: 3.1, delta: -0.4, count: 4)
        #expect(MoodTagInsightSection.badgeTitle(up) == "Sport \(MoodTagInsightSection.deltaString(0.7))")
        #expect(MoodTagInsightSection.symbol(up) == "arrow.up")
        #expect(MoodTagInsightSection.symbol(down) == "arrow.down")
    }
}
