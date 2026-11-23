import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// The chart drawn from single readings: an empty server series must not hide
/// the readings, and a page cut at its limit must be noticed.
@Suite("Chart points from readings and the page limit")
struct ChartRawPointsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func reading(_ id: String, daysAgo: Double, value: Double) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: id,
            kind: .walkingSpeed,
            recordedAt: now.addingTimeInterval(-daysAgo * 86400),
            value: .scalar(value),
            source: .appleHealth
        )
    }

    private static let emptyStats = SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)

    @Test("An empty series falls back to the readings, oldest first")
    func emptySeriesKeepsReadings() {
        let recent = [Self.reading("b", daysAgo: 1, value: 1.3), Self.reading("a", daysAgo: 3, value: 1.1)]
        let empty = MeasurementSeries(kind: .walkingSpeed, points: [], stats: Self.emptyStats)
        let points = ChartDetailStore.chartPoints(series: empty, recent: recent)
        #expect(points.map(\.id) == ["a", "b"])
        #expect(points.map(\.value) == [1.1, 1.3])
    }

    @Test("No series at all falls back to the readings as before")
    func missingSeriesKeepsReadings() {
        let recent = [Self.reading("a", daysAgo: 2, value: 1.2)]
        #expect(ChartDetailStore.chartPoints(series: nil, recent: recent).map(\.id) == ["a"])
    }

    @Test("A series with points wins over the readings")
    func seriesWins() {
        let point = SeriesPoint(id: "s1", at: Self.now, value: 9, secondary: nil)
        let series = MeasurementSeries(kind: .walkingSpeed, points: [point], stats: Self.emptyStats)
        let recent = [Self.reading("a", daysAgo: 2, value: 1.2)]
        #expect(ChartDetailStore.chartPoints(series: series, recent: recent).map(\.id) == ["s1"])
    }

    @Test("A full page that ends inside the range is cut")
    func fullPageInsideRangeIsCut() {
        let cutoff = Self.now.addingTimeInterval(-30 * 86400)
        let page = (0 ..< 400).map { Self.reading("r\($0)", daysAgo: Double($0) * 0.05, value: 1) }
        #expect(ChartDetailStore.recentPageIsCut(page, limit: 400, cutoff: cutoff))
    }

    @Test("A full page that reaches past the range start is not cut")
    func fullPageCoveringRangeIsNotCut() {
        let cutoff = Self.now.addingTimeInterval(-30 * 86400)
        let page = (0 ..< 400).map { Self.reading("r\($0)", daysAgo: Double($0) * 0.1, value: 1) }
        #expect(!ChartDetailStore.recentPageIsCut(page, limit: 400, cutoff: cutoff))
    }

    @Test("A page below its limit holds everything there is")
    func shortPageIsNotCut() {
        let cutoff = Self.now.addingTimeInterval(-365 * 86400)
        let page = (0 ..< 399).map { Self.reading("r\($0)", daysAgo: Double($0) * 0.01, value: 1) }
        #expect(!ChartDetailStore.recentPageIsCut(page, limit: 400, cutoff: cutoff))
        #expect(!ChartDetailStore.recentPageIsCut([], limit: 400, cutoff: cutoff))
    }

    @Test("The note under the chart names the limit in each language", arguments: ["de", "en", "nl"])
    func capNoteResolves(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let format = bundle.localizedString(forKey: "chart.card.rawCapped %lld", value: "MISSING", table: nil)
        #expect(format != "MISSING")
        let text = String(format: format, 400)
        #expect(text.contains("400"))
        #expect(!text.contains("%"))
    }
}
