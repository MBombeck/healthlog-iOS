import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Insights (R2 Phase B) — the per-tile `✦` AI-affordance gate.
/// Pins: AI shows ONLY for metric-shaped tiles + ONLY when the assistant is
/// configured; aux tiles (Mood / Stability / Compliance) never get a `✦`.
@Suite("Per-tile AI explainer gate")
struct MetricAIExplainerGateTests {
    @Test("Metric-shaped tile gets a ✦ when AI is configured")
    func metricShapedConfigured() {
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "WEIGHT", aiConfigured: true) == .weight)
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "RESTING_HR", aiConfigured: true) == .restingHeartRate)
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "ACTIVITY_STEPS", aiConfigured: true) == .steps)
    }

    @Test("No ✦ when the assistant is not configured")
    func noAffordanceWhenUnconfigured() {
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "WEIGHT", aiConfigured: false) == nil)
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "RESTING_HR", aiConfigured: false) == nil)
    }

    @Test("Aux tiles never get a ✦, even when AI is configured")
    func auxTilesNeverGetAffordance() {
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "MOOD_SCORE", aiConfigured: true) == nil)
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "MOOD_STABILITY", aiConfigured: true) == nil)
        #expect(InsightsTargetTileGrid.aiExplainerKind(for: "MEDICATION_COMPLIANCE", aiConfigured: true) == nil)
    }
}
