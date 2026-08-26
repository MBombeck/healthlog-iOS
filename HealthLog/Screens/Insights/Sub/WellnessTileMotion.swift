import CoreGraphics
import Foundation

/// **v0.14.11 Task C — the VERY subtle "living light" motion on the wellness
/// score tiles.**
///
/// A slow, barely-perceptible breathing of the existing white radial glow under
/// each ring (`WellnessGradientCard`), modulating BOTH the glow opacity and its
/// end-radius. The tiles are phase-offset by grid index so the six side-by-side
/// tiles NEVER pulse in unison — synchronised pulsing reads as "loading", an
/// offset breath reads as "alive". The operator was emphatic: *"auf keinen Fall
/// das Gefühl, da bewegt sich zu viel."* — so the amplitudes start on the LOW
/// side (almost imperceptible), and every knob is a named constant here so the
/// whole effect is tunable in ONE place.
///
/// **Reduce Motion → completely static.** The call site
/// (`WellnessGradientCard.glow`) skips the `TimelineView` entirely under Reduce
/// Motion and renders the `breath == 0` mid value — no animation, no flicker.
///
/// Pure + `nonisolated` so the same maths drives the live tile and the unit
/// tests (`InsightsScoreCardsBlockTests`) without a SwiftUI host.
enum WellnessTileMotion {
    /// Breathing period in seconds (one full sine cycle). Long + calm so the
    /// drift is sub-conscious. 6–8 s is the brief's target band; b174 operator
    /// retune ("ein minimal bisschen mehr") moved 7 s → 6 s — still in band,
    /// just a touch livelier.
    nonisolated static let periodSeconds: Double = 6

    /// Peak-to-peak amplitude of the GLOW-OPACITY breath, as a fraction of the
    /// base glow opacity. b174 operator retune: `0.05 → 0.075` (×1.5) — the
    /// glow opacity drifts ±7.5% around its base. Still subtle on one tile,
    /// reads a touch more alive across the offset grid.
    nonisolated static let opacityAmplitude: Double = 0.075

    /// Peak-to-peak amplitude of the GLOW-RADIUS breath, as a fraction of the
    /// base end-radius. b174 operator retune: `0.04 → 0.06` (×1.5) — the glow
    /// "bloom" gently grows/shrinks ±6%.
    nonisolated static let radiusAmplitude: Double = 0.06

    /// Per-tile phase offset (radians) applied by grid index so adjacent tiles
    /// are out of phase. `0.9` rad ≈ 51° — enough spread that no two neighbours
    /// breathe together, small enough that the grid still feels like one field.
    nonisolated static let perIndexPhase: Double = 0.9

    /// The base glow end-radius (the static value `WellnessGradientCard` used
    /// before motion). The breath modulates around this.
    nonisolated static let baseEndRadius: CGFloat = 90

    /// The capped `TimelineView` frame interval (seconds) for the living-light
    /// breath — 20 fps, the same cap the prism / cycle-glow drivers use
    /// (`InsightsPrismShader`, `HLCycleRingGlow`). The breath is a slow 6 s sine,
    /// so 20 fps is visually indistinguishable from display refresh while killing
    /// the per-frame redraw at up to 120 Hz. Shared by both tile-glow call sites
    /// (`InsightsTileSurface`, `WellnessGradientCard`).
    nonisolated static let frameInterval: Double = 1.0 / 20.0

    /// Whether the living-light breath should be PAUSED (rendered at its static
    /// `breath == 0` mid value). Pure predicate so the gate is unit-testable
    /// without a SwiftUI host: the breath pauses under Reduce Motion OR Low-Power,
    /// matching every other animated driver in the app.
    nonisolated static func isPaused(reduceMotion: Bool, lowPower: Bool) -> Bool {
        reduceMotion || lowPower
    }

    /// A low-frequency sine in `[-1, 1]` for `seconds` at tile `index`. The
    /// REDUCE-MOTION mid value is simply `breath(seconds:index:)`'s `0` (the call
    /// site passes `breath = 0` by not animating).
    nonisolated static func breath(seconds: Double, index: Int) -> Double {
        let omega = 2 * Double.pi / periodSeconds
        return sin(omega * seconds + Double(index) * perIndexPhase)
    }

    /// The glow-opacity SCALE for a breath value (`-1...1`) — a multiplier around
    /// `1.0` applied to the base `HLColor.wellnessTileGlow` (`Color.opacity()`
    /// multiplies). Breath `0` → exactly `1.0` (the static base glow).
    nonisolated static func opacityScale(breath: Double) -> Double {
        1 + opacityAmplitude * breath
    }

    /// The glow END-RADIUS for a breath value (`-1...1`). Breath `0` → the static
    /// base radius.
    nonisolated static func endRadius(breath: Double) -> CGFloat {
        baseEndRadius * (1 + radiusAmplitude * breath)
    }
}
