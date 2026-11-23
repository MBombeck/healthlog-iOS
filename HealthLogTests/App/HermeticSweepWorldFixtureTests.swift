import Foundation
@testable import HealthLog
import Testing

/// The picture walk's world has to agree with itself, or the pictures show
/// contradictions the app never made: a falling weight tile over a rising
/// line, a range that never changes the chart, a score with no pillar, a mood
/// pattern on another scale. Decoded the way the app decodes them.
@Suite("Hermetic sweep world fixtures")
struct HermeticSweepWorldFixtureTests {
    private func series(_ kind: String, days: Int? = nil) throws -> MeasurementSeries {
        var query = [URLQueryItem(name: "kind", value: kind)]
        if let days { query.append(URLQueryItem(name: "days", value: String(days))) }
        let answer = try #require(SweepFixtures.response(forPath: "/api/measurements/series", method: "GET", query: query))
        return try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: answer.body)
    }

    private func mean(_ values: some Collection<Double>) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    @Test("The series follows the requested range, as far back as the history reaches")
    func seriesFollowsRange() throws {
        #expect(try series("bloodPressure", days: 1).points.count == 1)
        #expect(try series("bloodPressure", days: 7).points.count == 7)
        #expect(try series("bloodPressure", days: 180).points.count == 180)
        #expect(try series("bloodPressure", days: 3650).points.count == 200)
        #expect(try series("bloodPressure").points.count == 30)
    }

    @Test("Weight falls over the month, the way the summary's tile says")
    func weightFalls() throws {
        let points = try series("weight", days: 30).points.map(\.value)
        #expect(points.last == 72.4)
        #expect(try #require(points.last) < points[points.count - 2])
        #expect(mean(points.suffix(15)) < mean(points.prefix(15)))
        let summary = try JSONDecoder.hlDefault.decode(DashboardSummary.self, from: Data(MarketingFixtures.summaryJSON.utf8))
        #expect(summary.metrics.first { $0.id == "weight" }?.trend == .down)
    }

    @Test("Today's reading never lies ahead of the clock")
    func noReadingInTheFuture() throws {
        let latest = try #require(series("pulse", days: 7).points.last)
        #expect(latest.at <= .now)
    }

    @Test("The type list answers a page of the newest rows")
    func listHonoursLimit() throws {
        let answer = try #require(SweepFixtures.response(
            forPath: "/api/measurements", method: "GET",
            query: [URLQueryItem(name: "type", value: "WEIGHT"), URLQueryItem(name: "limit", value: "50")]
        ))
        let list = try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: answer.body)
        #expect(list.measurements.count == 50)
        // Blood pressure comes as two pages, one per half, like the server's.
        for type in ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"] {
            let page = try #require(SweepFixtures.response(
                forPath: "/api/measurements", method: "GET",
                query: [URLQueryItem(name: "type", value: type), URLQueryItem(name: "limit", value: "90")]
            ))
            let rows = try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: page.body).measurements
            #expect(rows.count == 90)
            #expect(rows.allSatisfy { $0.type.rawValue == type })
        }
    }

    @Test("The recovery page has the wearable readings behind the overview's rings")
    func recoveryHasReadings() throws {
        let answer = try #require(SweepFixtures.response(
            forPath: "/api/measurements", method: "GET", query: [URLQueryItem(name: "type", value: "RECOVERY_SCORE")]
        ))
        let list = try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: answer.body)
        #expect(list.measurements.first?.value == 83)
        let summaries = try #require(SweepFixtures.response(
            forPath: "/api/analytics", method: "GET", query: [URLQueryItem(name: "slice", value: "summaries")]
        ))
        let availability = try JSONDecoder.hlDefault.decode(MeasurementAvailabilityDTO.self, from: summaries.body)
        #expect(availability.summaries["RECOVERY_SCORE"] != nil)
        #expect(availability.summaries["WEIGHT"] != nil)
    }

    @Test("An account that never chose counts every pillar")
    func healthScoreCountsPillars() throws {
        let answer = try #require(SweepFixtures.response(
            forPath: "/api/auth/me/health-score-config", method: "GET", query: []
        ))
        let config = try #require(JSONDecoder.hlDefault.decode(APIEnvelope<HealthScoreConfig>.self, from: answer.body).data)
        #expect(config.pillars == HealthScorePillar.known)
        #expect(!config.hasSelection)
    }

    @Test("The check-up the Today hint names is on the list and overdue")
    func checkupIsOverdue() throws {
        let answer = try #require(SweepFixtures.response(forPath: "/api/measurement-reminders", method: "GET", query: []))
        let rows = try JSONDecoder.hlDefault.decode([MeasurementReminderRow].self, from: answer.body)
        let checkup = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(try #require(checkup.nextDueAt) < .now)
    }

    @Test("The nutrient list has rows, and each row has its days")
    func nutrientsHaveData() throws {
        let overview = try #require(SweepFixtures.response(forPath: "/api/nutrients", method: "GET", query: []))
        let rows = try #require(JSONDecoder.hlDefault.decode(APIEnvelope<NutrientOverviewDTO>.self, from: overview.body).data)
        #expect(rows.nutrients.count == 5)
        let daily = try #require(SweepFixtures.response(
            forPath: "/api/nutrients/daily", method: "GET", query: [URLQueryItem(name: "nutrient", value: "magnesium")]
        ))
        let series = try #require(JSONDecoder.hlDefault.decode(APIEnvelope<NutrientDailySeriesDTO>.self, from: daily.body).data)
        #expect(series.days.count == 14)
    }

    @Test("Mood patterns stand on the same five-point scale as the mood average")
    func moodPatternsOnFivePointScale() throws {
        let relations = try JSONDecoder.hlDefault.decode(
            MoodRelationsResponse.self,
            from: Data(AreaMedsFixtures.moodInsightsJSON.utf8)
        )
        let patterns = try #require(relations.patterns)
        #expect(patterns.allSatisfy { $0.values.subject <= 5 && $0.values.comparison <= 5 })
        let entries = try JSONDecoder.hlDefault.decode(MoodListResponse.self, from: Data(AreaMedsFixtures.moodEntriesJSON.utf8))
        #expect(entries.entries.allSatisfy { $0.moodLoggedAt <= .now })
    }

    @Test("The medication list, the detail history and the day counters tell one story, never ahead of the clock")
    func medicationsAgree() throws {
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(MarketingFixtures.medicationsJSON.utf8)) as? [[String: Any]]
        )
        let iso = ISO8601DateFormatter()
        for row in rows {
            let id = try #require(row["id"] as? String)
            let listed = (row["lastTakenAt"] as? String).flatMap(iso.date(from:))
            let history = AreaMedsDetailFixtures.lastTakenAt(medicationID: id)
            // Same instant to the second: the list and the detail read the same dose.
            #expect(listed?.timeIntervalSince1970.rounded() == history?.timeIntervalSince1970.rounded(), "\(id)")
            if let listed { #expect(listed <= .now, "\(id) was taken in the future") }
            #expect(row["todayEventCount"] as? Int == AreaMedsDetailFixtures.todayEventCount(medicationID: id))
        }
        // Trulicity's weekly dose shows in the list as it does in the detail.
        #expect(rows.contains { $0["id"] as? String == AreaMedsDetailFixtures.trulicityID && $0["lastTakenAt"] is String })
        let today = AreaMedsDetailFixtures.todayIntakes()
        #expect(MarketingFixtures.todayCompliance["scheduledToday"] == today.count)
        #expect(MarketingFixtures.todayCompliance["takenToday"] == today.count { $0["status"] as? String == "taken" })
    }
}
