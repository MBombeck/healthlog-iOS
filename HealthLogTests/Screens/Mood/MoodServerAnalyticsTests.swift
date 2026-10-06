import Foundation
@testable import HealthLog
import Testing

/// #115 · 1.3 — mood day means and stability come from the server's mood
/// analytics, not from bucketing entries on the device calendar with the app's
/// own formula. Shapes follow `MoodDailySeries` (`GET /api/mood/analytics`) and
/// `MoodAggregates.stability` (`GET /api/mood/insights`) in
/// `docs/api/openapi.yaml` at `v1.39.0`.
@Suite("Mood analytics — server day means + stability (#115 1.3)")
struct MoodServerAnalyticsTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// 2023-11-14T22:13:20Z.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static let series = #"""
    {
      "entries": [
        { "date": "2023-11-12", "score": 2.5, "samples": 2 },
        { "date": "2023-11-13", "score": 4.0, "samples": 1 },
        { "date": "2023-11-14", "score": 3.0, "samples": 1 }
      ],
      "summary": {
        "count": 3, "latest": 3.0, "min": 2.5, "max": 4.0, "mean": 3.17, "median": 3.0,
        "avg7": 3.17, "avg30": 3.17,
        "slope7": { "slope": 0.25, "direction": "up", "confidence": 0.4 },
        "slope30": { "slope": 0.1, "direction": "up", "confidence": 0.2 },
        "anomalyCount": 0, "avg30LastMonth": 2.9, "avg30LastYear": null
      }
    }
    """#

    private static func decodeSeries() throws -> MoodAnalyticsEnrichment {
        try JSONDecoder.hlDefault.decode(MoodAnalyticsEnrichment.self, from: Data(series.utf8))
    }

    @Test("the v1.39 series decodes, including TrendSlope objects in the summary")
    func decodesSeries() throws {
        let series = try Self.decodeSeries()
        #expect(series.days.count == 3)
        #expect(series.slope7 == 0.25)
        #expect(series.slope30 == 0.1)
        #expect(series.avg30LastMonth == 2.9)
    }

    @Test("the server's profile-day means are the spine, not a device-calendar bucketing")
    func serverDaysAreTheSpine() throws {
        let series = try Self.decodeSeries()
        // A single late-evening entry that a device-calendar bucketing would
        // put on its own day with a mean of 5.
        let entries = [MoodEntry(id: "e1", recordedAt: Self.now, score: 5, tags: [])]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.utc, enrichment: series)
        #expect(insight.dailyAverages.map(\.average) == [2.5, 4.0, 3.0])
        #expect(insight.dailyAverages.last?.day == Self.utc.date(from: DateComponents(year: 2023, month: 11, day: 14)))
        #expect(insight.slope7 == 0.25)
        #expect(insight.dayCount == 3)
    }

    @Test("the period window cuts the server days like it cuts the entries")
    func windowCutsServerDays() throws {
        let series = try Self.decodeSeries()
        let entries = [MoodEntry(id: "e1", recordedAt: Self.now, score: 3, tags: [])]
        let insight = MoodInsights.compute(
            entries: entries, now: Self.now, calendar: Self.utc, enrichment: series, windowDays: 1
        )
        #expect(insight.dailyAverages.map(\.average) == [4.0, 3.0])
    }

    @Test("the server's stability decodes from /api/mood/insights; a new band word is tolerated")
    func stabilityFromServer() throws {
        let json = #"""
        { "stability": { "score": 73, "stdDev": 0.405, "band": "steady", "days": 212 },
          "tagInfluence": { "flat": [], "structured": [] }, "betterDays": [] }
        """#
        let response = try JSONDecoder.hlDefault.decode(MoodRelationsResponse.self, from: Data(json.utf8))
        #expect(response.stability == MoodStability(score: 73, stdDev: 0.405, band: .steady, days: 212))

        let future = #"{ "stability": { "score": 12, "stdDev": 1.4, "band": "zz-new", "days": 30 } }"#
        let tolerated = try JSONDecoder.hlDefault.decode(MoodRelationsResponse.self, from: Data(future.utf8))
        #expect(tolerated.stability?.band == .unknown)

        let sparse = #"{ "stability": null }"#
        #expect(try JSONDecoder.hlDefault.decode(MoodRelationsResponse.self, from: Data(sparse.utf8)).stability == nil)
    }

    @Test("the stability band is the server's; veryVariable is the only flagged one")
    func bandsAreTheServers() {
        #expect(MoodStability.Band(wireValue: "veryVariable") == .veryVariable)
        #expect(MoodStability.Band.veryVariable.isFlagged)
        #expect(!MoodStability.Band.variable.isFlagged)
    }
}
