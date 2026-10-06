import Foundation
@testable import HealthLog
import Testing

/// **#115 B6 — three remaining places where a new server token cost data.**
///
/// - `MeasurementSeries.kind` decoded `MetricKind` strictly: a kind this build
///   cannot name failed the whole chart payload.
/// - The dashboard layout PUT rebuilt `enabledHeroItemKinds` and
///   `selectedScoreRings` from the closed Swift enums, so a token only a newer
///   server knows was switched off by every save of the picker.
/// - `NutrientDailySeriesDTO.reference` vanished whole when its `kind` was new.
///
/// Wire shapes follow `docs/api/openapi.yaml` at v1.39.0
/// (`MeasurementsSeriesResponse`, `DashboardLayout`, `NutrientDailyResponse`);
/// only the new token is invented.
@Suite("#115 B6 — server tokens this build cannot name")
struct ServerTokenToleranceB6Tests {
    // MARK: - Series kind

    @Test("a series whose kind this build cannot name keeps its points")
    func seriesUnknownKindKeepsPoints() throws {
        let json = """
        {"kind":"skinConductance","unit":"µS",
         "points":[{"id":"m1","at":"2026-09-20T08:00:00Z","value":4.2,"secondary":null}],
         "stats":{"mean":4.2,"min":4.2,"max":4.2,"stdDev":0,"count":1}}
        """
        let series = try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(json.utf8))
        #expect(series.kind == .unknown)
        #expect(series.points.map(\.value) == [4.2])
        #expect(series.unit == "µS")
    }

    // MARK: - Layout PUT

    private func layout(_ fields: String) throws -> DashboardWidgetLayout {
        try JSONDecoder.hlDefault.decode(
            DashboardWidgetLayout.self,
            from: Data(#"{"version":1,"widgets":[],\#(fields)}"#.utf8)
        )
    }

    private func body(_ layout: DashboardWidgetLayout) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(layout)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("saving the hero-item picker keeps a kind only the server knows")
    func heroItemPickerKeepsUnknownKind() throws {
        let stored = try layout(#""enabledHeroItemKinds":["dose_window","air_quality","milestone"]"#)
        #expect(stored.resolvedEnabledHeroItemKinds == [.doseWindow, .milestone])

        let next = stored.settingEnabledHeroItemKinds([.doseWindow, .syncIssue])

        let sent = try #require(try body(next)["enabledHeroItemKinds"] as? [String])
        #expect(sent == ["dose_window", "sync_issue", "air_quality"])
    }

    @Test("switching the rail off still keeps the unknown kind the picker never showed")
    func emptyPickerKeepsUnknownKind() throws {
        let stored = try layout(#""enabledHeroItemKinds":["air_quality"]"#)
        let sent = try #require(try body(stored.settingEnabledHeroItemKinds([]))["enabledHeroItemKinds"] as? [String])
        #expect(sent == ["air_quality"])
    }

    @Test("saving the score-ring picker keeps a ring only the server knows, within the cap")
    func scoreRingPickerKeepsUnknownRing() throws {
        let stored = try layout(#"""
        "selectedScoreRings":["STRESS_SCORE","MED_COMPLIANCE"],
        "heroRingOrder":["STRESS_SCORE","HEALTH_SCORE","MED_COMPLIANCE"]
        """#)

        let next = stored.settingScoreRings(selected: [.medCompliance, .sleepScore], heroOrder: [.healthScore, .medCompliance])

        let sent = try body(next)
        #expect(sent["selectedScoreRings"] as? [String] == ["MED_COMPLIANCE", "SLEEP_SCORE", "STRESS_SCORE"])
        let order = try #require(sent["heroRingOrder"] as? [String])
        #expect(order.contains("STRESS_SCORE"))
        #expect(order.count <= HeroRingID.maxOrderLength)
    }

    @Test("a full visible selection leaves no room: the cap wins over the unknown ring")
    func scoreRingCapWins() throws {
        let stored = try layout(#""selectedScoreRings":["STRESS_SCORE"]"#)
        let next = stored.settingSelectedScoreRings([.readiness, .recovery, .sleepScore])
        #expect(try body(next)["selectedScoreRings"] as? [String] == ["READINESS", "RECOVERY_SCORE", "SLEEP_SCORE"])
    }

    // MARK: - Nutrient reference

    @Test("a reference with a new EFSA kind keeps its value, direction and source")
    func nutrientReferenceUnknownKindIsKept() throws {
        let json = """
        {"nutrient":"vitamin_d","unit":"µg","windowDays":30,
         "days":[{"day":"2026-09-20","amount":5}],
         "reference":{"kind":"UL","direction":"target","value":15,"source":"EFSA DRV 2016"}}
        """
        let series = try JSONDecoder.hlDefault.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        let reference = try #require(series.reference)
        #expect(reference.kind == .unknown)
        #expect(reference.direction == .target)
        #expect(reference.value == 15)
        #expect(reference.source == "EFSA DRV 2016")
    }

    @Test("an unknown direction still hides the reference — target vs. ceiling is not guessed")
    func nutrientReferenceUnknownDirectionStaysHidden() throws {
        let json = """
        {"nutrient":"vitamin_d","unit":"µg","windowDays":30,"days":[],
         "reference":{"kind":"AI","direction":"sideways","value":15,"source":"EFSA"}}
        """
        let series = try JSONDecoder.hlDefault.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        #expect(series.reference == nil)
    }
}
