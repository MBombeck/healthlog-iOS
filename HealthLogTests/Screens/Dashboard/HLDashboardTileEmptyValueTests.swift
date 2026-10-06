import Foundation
@testable import HealthLog
import Testing

/// **H2 (1.1.0) — an empty tile shows no number.**
///
/// The QA sweep photographed a steps tile reading "8.421 Schritte" in grey
/// with "Noch keine Daten" under it (resting heart rate and HRV the same):
/// the context line and the grey tint came from the resolved `.empty` state,
/// the number still came from the summary snapshot. `MetricDisplay` — which
/// the hero and the list render — already says "—" for every empty reason;
/// the tile now says the same.
@MainActor
@Suite("HLDashboardTile — empty state value")
struct HLDashboardTileEmptyValueTests {
    private let steps = DashboardMetric(
        id: "steps", kind: .steps, title: "Schritte",
        latestValue: 8421, secondaryValue: nil, unit: "steps", trend: .up,
        sparkline: [6200, 7100, 8000, 8421], updatedAt: Date()
    )

    private let restingHeartRate = DashboardMetric(
        id: "restingHeartRate", kind: .restingHeartRate, title: "Ruhepuls",
        latestValue: 58, secondaryValue: nil, unit: "bpm", trend: .flat,
        sparkline: [60, 59, 58], updatedAt: Date()
    )

    @Test("Resolved empty (no data) renders the dash, like MetricDisplay")
    func noDataRendersDash() {
        for metric in [steps, restingHeartRate] {
            let tile = HLDashboardTile(metric: metric, dataState: .empty(reason: .noData))
            let display = MetricDisplay(metric: metric, dataState: .empty(reason: .noData))
            #expect(tile.formattedValueText == "—")
            #expect(tile.formattedValueText == display.valueText)
        }
    }

    @Test("Resolved empty (outside range) renders the dash too")
    func outsideRangeRendersDash() {
        let old = Date().addingTimeInterval(-20 * 86400)
        let tile = HLDashboardTile(metric: restingHeartRate, dataState: .empty(reason: .outsideRange(latestAt: old)))
        #expect(tile.formattedValueText == "—")
    }

    @Test("Before resolution the summary snapshot still paints the first frame")
    func unknownKeepsSnapshot() {
        let tile = HLDashboardTile(metric: restingHeartRate, dataState: .unknown)
        #expect(tile.formattedValueText != "—")
    }
}
