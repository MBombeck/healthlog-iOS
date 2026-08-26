import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Insights (R2 Phase A) — pure-helper locks for the unified
/// `RangeBand` primitive + the grid's server-payload → band builder. These
/// pin the pct→width clamping + the band-gating contract without a SwiftUI
/// render pass.
@Suite("RangeBand + grid band builder")
struct HLRangeBandTests {
    // MARK: - fillFraction clamps

    @Test("fillFraction maps 0…100 onto 0…1")
    func fillFractionMidpoint() {
        #expect(RangeBand.fillFraction(pct: 50) == 0.5)
        #expect(RangeBand.fillFraction(pct: 0) == 0)
        #expect(RangeBand.fillFraction(pct: 100) == 1)
    }

    @Test("fillFraction clamps out-of-range payloads")
    func fillFractionClamps() {
        #expect(RangeBand.fillFraction(pct: 131) == 1)
        #expect(RangeBand.fillFraction(pct: -10) == 0)
    }

    // MARK: - tone thresholds (mirror BPStatusCard verbatim)

    @Test("tone is ok at ≥80, warn 50–79, bad below 50")
    func toneThresholds() {
        #expect(RangeBand.tone(pct: 88) == .ok)
        #expect(RangeBand.tone(pct: 80) == .ok)
        #expect(RangeBand.tone(pct: 79) == .warn)
        #expect(RangeBand.tone(pct: 50) == .warn)
        #expect(RangeBand.tone(pct: 49) == .bad)
        #expect(RangeBand.tone(pct: 0) == .bad)
    }

    // MARK: - grid band builder

    @Test("rangeBand returns nil when no range configured")
    func bandNilWithoutRange() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: nil,
            insufficient: false,
            daysInRange30d: 20,
            daysLogged30d: 28,
            unit: "kg",
            type: "WEIGHT"
        )
        #expect(band == nil)
    }

    @Test("rangeBand returns nil when window is insufficient")
    func bandNilWhenInsufficient() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: .init(min: 71, max: 74),
            insufficient: true,
            daysInRange30d: 20,
            daysLogged30d: 28,
            unit: "kg",
            type: "WEIGHT"
        )
        #expect(band == nil)
    }

    @Test("rangeBand returns nil when nothing logged in the window")
    func bandNilWhenNothingLogged() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: .init(min: 71, max: 74),
            insufficient: false,
            daysInRange30d: 0,
            daysLogged30d: 0,
            unit: "kg",
            type: "WEIGHT"
        )
        #expect(band == nil)
    }

    @Test("rangeBand computes the in-range percentage over logged days")
    func bandComputesPct() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: .init(min: 71, max: 74),
            insufficient: false,
            daysInRange30d: 21,
            daysLogged30d: 28,
            unit: "kg",
            type: "WEIGHT"
        )
        #expect(band != nil)
        // 21 / 28 = 75 %
        #expect(band?.pctInRange == 75)
        #expect(band?.unit == "kg")
    }

    @Test("rangeBand clamps in-range count to logged-day total")
    func bandClampsInRangeToLogged() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: .init(min: 60, max: 70),
            insufficient: false,
            daysInRange30d: 40, // malformed payload — more in-range than logged
            daysLogged30d: 28,
            unit: "bpm",
            type: "RESTING_HR"
        )
        #expect(band?.pctInRange == 100)
    }

    @Test("rangeBand formats integer-metric bounds without decimals")
    func bandIntegerBounds() {
        let band = InsightsTargetTileGrid.rangeBand(
            range: .init(min: 60, max: 70),
            insufficient: false,
            daysInRange30d: 14,
            daysLogged30d: 28,
            unit: "bpm",
            type: "RESTING_HR"
        )
        #expect(band?.lowerLabel == "60")
        #expect(band?.upperLabel == "70")
        #expect(band?.pctInRange == 50)
    }
}
