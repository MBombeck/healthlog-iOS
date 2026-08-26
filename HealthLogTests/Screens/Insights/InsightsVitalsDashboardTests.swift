import Foundation
@testable import HealthLog
import Testing

/// W52 (v0.11 overview rework) — pins the iOS `InsightsVitalsDashboard` tile
/// resolution + self-suppression contract (the iOS twin of the web
/// `VitalsDashboard`'s per-tile data-availability gate). Pure `nonisolated
/// static` logic, no SwiftUI host.
@Suite("Insights vitals dashboard")
struct InsightsVitalsDashboardTests {
    private func metric(
        _ kind: MetricKind,
        value: Double?,
        trend: TrendIndicator = .flat,
        sparkline: [Double] = []
    ) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.rawValue,
            latestValue: value,
            secondaryValue: nil,
            unit: "",
            trend: trend,
            sparkline: sparkline,
            updatedAt: nil
        )
    }

    @Test("No metrics → no tiles (whole section self-suppresses)")
    func emptyPoolSuppresses() {
        let tiles = InsightsVitalsDashboard.tiles(from: [])
        #expect(tiles.isEmpty)
    }

    @Test("A vital with no latestValue is dropped")
    func valuelessVitalDropped() {
        let tiles = InsightsVitalsDashboard.tiles(from: [
            metric(.restingHeartRate, value: nil)
        ])
        #expect(tiles.isEmpty)
    }

    @Test("Non-vital metrics never produce a vital tile")
    func nonVitalsIgnored() {
        let tiles = InsightsVitalsDashboard.tiles(from: [
            metric(.steps, value: 8000),
            metric(.bloodPressure, value: 120)
        ])
        #expect(tiles.isEmpty)
    }

    @Test("Value-bearing vitals surface in the web SECTION_VITALS order")
    func vitalsOrdered() {
        // Supplied out of order — the resolver must re-impose the canonical
        // order (resting HR → HRV → respiratory → SpO₂ → temp → glucose →
        // weight). Here: weight + restingHR + spo2.
        let tiles = InsightsVitalsDashboard.tiles(from: [
            metric(.weight, value: 72.4),
            metric(.spo2, value: 98),
            metric(.restingHeartRate, value: 58)
        ])
        #expect(tiles.map(\.kind) == [.restingHeartRate, .spo2, .weight])
    }

    @Test("Tile carries the latest value + unit + trend + series through")
    func tileContent() throws {
        let tiles = InsightsVitalsDashboard.tiles(from: [
            metric(.restingHeartRate, value: 58, trend: .down, sparkline: [60, 59, 58])
        ])
        let tile = try #require(tiles.first)
        #expect(tile.kind == .restingHeartRate)
        #expect(tile.trend == .down)
        #expect(tile.series == [60, 59, 58])
        // Value text leads with the formatted reading.
        #expect(tile.valueText.contains("58"))
    }

    // MARK: - W5-1 dedup (a metric already shown as a target tile is dropped)

    @Test("A vital covered by a configured target is dropped from the Vitals block")
    func excludedVitalDropped() {
        let pool = [
            metric(.restingHeartRate, value: 58),
            metric(.weight, value: 72.4),
            metric(.hrv, value: 44)
        ]
        // Weight + resting-HR are covered by the target grid → excluded here.
        let tiles = InsightsVitalsDashboard.tiles(
            from: pool,
            excluding: [.weight, .restingHeartRate]
        )
        #expect(tiles.map(\.kind) == [.hrv])
    }

    @Test("Empty exclusion set renders every value-bearing vital (no dedup)")
    func emptyExclusionKeepsAll() {
        let pool = [
            metric(.restingHeartRate, value: 58),
            metric(.weight, value: 72.4)
        ]
        let tiles = InsightsVitalsDashboard.tiles(from: pool, excluding: [])
        #expect(Set(tiles.map(\.kind)) == [.restingHeartRate, .weight])
    }

    @Test("Excluding every present vital self-suppresses the section")
    func excludeAllSuppresses() {
        let tiles = InsightsVitalsDashboard.tiles(
            from: [metric(.weight, value: 72.4)],
            excluding: [.weight]
        )
        #expect(tiles.isEmpty)
    }
}
