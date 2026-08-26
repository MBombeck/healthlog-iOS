import Foundation
@testable import HealthLog
import Testing

/// **v0.14.11 (Task C)** — pure contracts behind the score-tile "living light"
/// glow breath (`WellnessTileMotion`): a slow low-frequency sine, phase-offset
/// per tile, that resolves to the EXACT static mid value at `breath == 0` (the
/// value rendered under Reduce Motion).
///
/// Exercised off the main actor (no SwiftUI host) — only the pure
/// `nonisolated static` helpers the live views feed are touched.
@Suite("Score-tile living-light motion")
struct ScoreTileMotionTests {
    // MARK: - Task C — living-light motion resolves static under reduce-motion

    @Test("breath == 0 → glow opacity-scale 1.0 and base radius (the Reduce-Motion mid value)")
    func reduceMotionMidValueIsStatic() {
        // Reduce Motion renders `breath = 0`: opacity unchanged (scale 1.0), radius = base.
        #expect(WellnessTileMotion.opacityScale(breath: 0) == 1.0)
        #expect(WellnessTileMotion.endRadius(breath: 0) == WellnessTileMotion.baseEndRadius)
    }

    @Test("amplitudes are small (almost-imperceptible) and within the brief's band")
    func amplitudesAreLow() {
        // b174 operator retune (×1.5): opacity drifts ≤ ±7.5%, radius ≤ ±6% —
        // a touch livelier than the v0.14.11 baseline, still subtle.
        #expect(WellnessTileMotion.opacityScale(breath: 1) <= 1.075)
        #expect(WellnessTileMotion.opacityScale(breath: -1) >= 0.925)
        #expect(WellnessTileMotion.endRadius(breath: 1) <= WellnessTileMotion.baseEndRadius * 1.06)
        #expect(WellnessTileMotion.endRadius(breath: -1) >= WellnessTileMotion.baseEndRadius * 0.94)
        // Period is in the calm 6–8 s band.
        #expect(WellnessTileMotion.periodSeconds >= 6 && WellnessTileMotion.periodSeconds <= 8)
    }

    @Test("adjacent tiles are phase-offset → they never breathe in unison")
    func tilesArePhaseOffset() {
        // At a fixed instant, tile 0 and tile 1 differ by the per-index phase, so
        // their breath values differ — synchronized pulsing (the 'loading' read)
        // is structurally impossible.
        let seconds = 0.0
        let b0 = WellnessTileMotion.breath(seconds: seconds, index: 0)
        let b1 = WellnessTileMotion.breath(seconds: seconds, index: 1)
        #expect(abs(b0 - b1) > 0.0001)
        #expect(WellnessTileMotion.perIndexPhase > 0)
    }

    @Test("breath is a bounded sine in [-1, 1] across a full period")
    func breathIsBoundedSine() {
        for step in 0 ... 14 {
            let v = WellnessTileMotion.breath(seconds: Double(step) * 0.5, index: 3)
            #expect(v >= -1.0 && v <= 1.0)
        }
    }

    // MARK: - W-B187 — Low-Power gate + frame cap parity

    @Test("breath is PAUSED under Low-Power (not just Reduce Motion)")
    func pausesUnderLowPower() {
        // W-B187: the tile-glow drivers (`InsightsTileSurface`,
        // `WellnessGradientCard`) now gate on Low-Power AND Reduce Motion, matching
        // every other animated driver (prism, cycle-glow). Previously only
        // Reduce Motion paused them.
        #expect(WellnessTileMotion.isPaused(reduceMotion: false, lowPower: true))
        #expect(WellnessTileMotion.isPaused(reduceMotion: true, lowPower: false))
        #expect(WellnessTileMotion.isPaused(reduceMotion: true, lowPower: true))
    }

    @Test("breath RUNS only when neither Reduce Motion nor Low-Power is on")
    func runsOnlyWhenUngated() {
        // No visual change when not in Low-Power and not Reduce Motion — the
        // breath still animates exactly as before.
        #expect(WellnessTileMotion.isPaused(reduceMotion: false, lowPower: false) == false)
    }

    @Test("frame interval is capped at the canonical 20 fps driver rate")
    func frameIntervalIsCapped() {
        // The driver no longer runs at full display refresh (up to 120 Hz); it's
        // capped to the same 20 fps interval the prism / cycle-glow drivers use.
        #expect(WellnessTileMotion.frameInterval == 1.0 / 20.0)
    }
}
