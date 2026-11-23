import Foundation
@testable import HealthLog
import Testing

/// The overview and special-page changes of E-P2 part B: the mood drill
/// row keeps its count wording, and the vitals cards carry their value as a
/// number in the account's unit for the compact value.
@MainActor
@Suite("E-P2 B Insights overview and special pages")
struct EP2BInsightsPagesTests {
    // MARK: - Mood drill row

    @Test("the mood drill row keeps the period count wording")
    func moodDrillRowDetail() {
        #expect(MoodDrillDownRow.detail(count: 3, hasDataOutsideRange: false).key == "%lld entries in the period")
        #expect(MoodDrillDownRow.detail(count: 0, hasDataOutsideRange: true).key == "Entries outside the period")
        #expect(MoodDrillDownRow.detail(count: 0, hasDataOutsideRange: false).key == "No entries")
    }

    // MARK: - Vitals compact value

    private static func metric(_ kind: MetricKind, value: Double, unit: String) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue, kind: kind, title: "", latestValue: value, secondaryValue: nil,
            unit: unit, trend: .flat, sparkline: [], updatedAt: nil
        )
    }

    @Test("a vital tile carries the number and unit the compact value shows")
    func vitalTileCompactValue() throws {
        let pool = [Self.metric(.weight, value: 73.5, unit: "kg")]
        let metricTile = try #require(
            InsightsVitalsDashboard.tiles(from: pool, units: AccountUnitDisplayTests.metric).first
        )
        #expect(metricTile.displayValue == 73.5)
        #expect(metricTile.unit == .kilograms)
        #expect(metricTile.fractionDigits == 1 ... 1)

        let imperialTile = try #require(
            InsightsVitalsDashboard.tiles(from: pool, units: AccountUnitDisplayTests.imperial).first
        )
        #expect(imperialTile.unit == .pounds)
        let pounds = try #require(imperialTile.displayValue)
        #expect(abs(pounds - 73.5 / 0.45359237) < 0.01)
    }

    @Test("a vital without a fixed account precision keeps up to one decimal")
    func vitalTileDefaultPrecision() throws {
        let pool = [Self.metric(.restingHeartRate, value: 58, unit: "bpm")]
        let tile = try #require(InsightsVitalsDashboard.tiles(from: pool).first)
        #expect(tile.displayValue == 58)
        #expect(tile.unit == .beatsPerMinute)
        #expect(tile.fractionDigits == HLValueFormat.defaultFractionDigits)
    }
}
