import Foundation
@testable import HealthLog
import Testing

/// v0.6.1.10 Y9-B/D — regression locks for the additions
/// `InsightsTargetTileGrid` picked up in the Y9 wave: the
/// `kindForChartDetail` mapping that routes a tile tap into
/// `ChartDetailScreen`, and the `hasData` auto-hide gate.
@Suite("InsightsTargetTileGrid Y9 additions")
@MainActor
struct InsightsTargetTileGridY9Tests {
    // MARK: - kindForChartDetail (Y9-B)

    @Test("WEIGHT maps to MetricKind.weight for the chart-detail push")
    func weightMaps() {
        #expect(InsightsTargetTileGrid.kindForChartDetail("WEIGHT") == .weight)
    }

    @Test("RESTING_HR maps to MetricKind.restingHeartRate")
    func restingHrMaps() {
        #expect(InsightsTargetTileGrid.kindForChartDetail("RESTING_HR") == .restingHeartRate)
    }

    @Test("PULSE maps to MetricKind.pulse")
    func pulseMaps() {
        #expect(InsightsTargetTileGrid.kindForChartDetail("PULSE") == .pulse)
    }

    @Test("ACTIVITY_STEPS maps to MetricKind.steps")
    func stepsMaps() {
        #expect(InsightsTargetTileGrid.kindForChartDetail("ACTIVITY_STEPS") == .steps)
    }

    @Test("Mood + Compliance still map to nil for the MetricKind route")
    func moodAndComplianceReturnNil() {
        // The `kindForChartDetail` route stays metric-only — Mood /
        // Stability / Compliance carry no `MetricKind` counterpart. The
        // companion `hasAuxDestination` switch (v0.6.2.9 Y10.8-C5/C6/C7)
        // wires those three tiles to dedicated auxiliary chart-detail
        // screens.
        #expect(InsightsTargetTileGrid.kindForChartDetail("MOOD_SCORE") == nil)
        #expect(InsightsTargetTileGrid.kindForChartDetail("MOOD_STABILITY") == nil)
        #expect(InsightsTargetTileGrid.kindForChartDetail("MEDICATION_COMPLIANCE") == nil)
    }

    // MARK: - hasAuxDestination (Y10.8-C5/C6/C7)

    @Test("MOOD_SCORE has an auxiliary destination so the tile is tappable")
    func moodScoreHasAuxDestination() {
        #expect(InsightsTargetTileGrid.hasAuxDestination("MOOD_SCORE"))
    }

    @Test("MOOD_STABILITY has an auxiliary destination so the tile is tappable")
    func moodStabilityHasAuxDestination() {
        #expect(InsightsTargetTileGrid.hasAuxDestination("MOOD_STABILITY"))
    }

    @Test("MEDICATION_COMPLIANCE has an auxiliary destination so the tile is tappable")
    func medicationComplianceHasAuxDestination() {
        #expect(InsightsTargetTileGrid.hasAuxDestination("MEDICATION_COMPLIANCE"))
    }

    @Test("Metric-shaped types are not routed through the auxiliary destination")
    func metricShapedTypesHaveNoAuxDestination() {
        // WEIGHT / RESTING_HR / etc. already push the canonical
        // `ChartDetailScreen` via `kindForChartDetail`. The aux switch
        // must stay disjoint so we don't double-route those tiles.
        #expect(InsightsTargetTileGrid.hasAuxDestination("WEIGHT") == false)
        #expect(InsightsTargetTileGrid.hasAuxDestination("RESTING_HR") == false)
        #expect(InsightsTargetTileGrid.hasAuxDestination("ACTIVITY_STEPS") == false)
    }

    // MARK: - hasData auto-hide gate (Y9-D1)

    @Test("hasData returns false when current and average30 are both nil")
    func hasDataFalseWhenEmpty() {
        let target = makeTarget(current: nil, average30: nil)
        #expect(InsightsTargetTileGrid.hasData(target) == false)
    }

    @Test("hasData returns true when only current is present")
    func hasDataTrueWhenCurrentOnly() {
        let target = makeTarget(current: 72.4, average30: nil)
        #expect(InsightsTargetTileGrid.hasData(target) == true)
    }

    @Test("hasData returns true when only average30 is present")
    func hasDataTrueWhenAverageOnly() {
        let target = makeTarget(current: nil, average30: 72.8)
        #expect(InsightsTargetTileGrid.hasData(target) == true)
    }

    // MARK: - daysInRangeLine (v0.7.0 W-API-RENDER)

    @Test("daysInRangeLine renders 'X von 30 Tagen' when a range exists and days are logged")
    func daysInRangeLineRendersTally() {
        let line = InsightsTargetTileGrid.daysInRangeLine(
            hasRange: true,
            insufficient: false,
            daysInRange30d: 23,
            daysLogged30d: 28
        )
        #expect(line != nil)
        // German-source key — the value is interpolated, the "23" must appear.
        #expect(line?.contains("23") == true)
    }

    @Test("daysInRangeLine is nil without a target range (no in-band claim possible)")
    func daysInRangeLineNilWithoutRange() {
        let line = InsightsTargetTileGrid.daysInRangeLine(
            hasRange: false,
            insufficient: false,
            daysInRange30d: 23,
            daysLogged30d: 28
        )
        #expect(line == nil)
    }

    @Test("daysInRangeLine is nil when insufficient data or nothing logged")
    func daysInRangeLineNilWhenNoSignal() {
        #expect(InsightsTargetTileGrid.daysInRangeLine(
            hasRange: true, insufficient: true, daysInRange30d: 0, daysLogged30d: 0
        ) == nil)
        #expect(InsightsTargetTileGrid.daysInRangeLine(
            hasRange: true, insufficient: false, daysInRange30d: 0, daysLogged30d: 0
        ) == nil)
    }

    @Test("daysInRangeLine clamps an out-of-bounds in-range count to 30")
    func daysInRangeLineClamps() {
        // Malformed server payload (daysInRange > 30) must never render "31 von 30".
        let line = InsightsTargetTileGrid.daysInRangeLine(
            hasRange: true, insufficient: false, daysInRange30d: 31, daysLogged30d: 30
        )
        #expect(line?.contains("30") == true)
        #expect(line?.contains("31") == false)
    }

    // MARK: - Helpers

    private func makeTarget(
        current: Double?,
        average30: Double?
    ) -> InsightsTargetsResponseDTO.TargetItem {
        InsightsTargetsResponseDTO.TargetItem(
            type: "WEIGHT",
            label: "Gewicht",
            current: current,
            average30: average30,
            trend: nil,
            unit: "kg",
            range: nil,
            classification: nil,
            source: "weight",
            daysInRange7d: 0,
            daysLogged7d: 0,
            daysInRange30d: 0,
            daysLogged30d: 0,
            lastMetGoalAt: nil,
            streakDays: 0,
            insufficientData: false,
            consistency7d: []
        )
    }
}
