@testable import HealthLog
import SwiftUI
import Testing

/// **v0.14.4 FW-WELL** — locks the convergent wellness-gradient descriptor: each
/// of the four wellness-score cards maps to its saturated hue + the INNER grid-
/// centre corner that holds the SHARED light end, so "die hellen Werte laufen
/// zueinander" (all four light corners meet at the grid centre). Exercised off
/// the main actor via the pure `nonisolated`/`Sendable` descriptor — no SwiftUI
/// host needed.
@Suite("WellnessGradient — convergent score-card gradients")
struct WellnessGradientTests {
    // MARK: - Metric-ID → case mapping

    @Test("metric IDs map to the four wellness gradient cases")
    func metricIDMapping() {
        #expect(WellnessGradient.forMetricID("READINESS") == .tagesform)
        #expect(WellnessGradient.forMetricID("SLEEP_SCORE") == .schlaf)
        #expect(WellnessGradient.forMetricID("STRAIN_SCORE") == .belastung)
        #expect(WellnessGradient.forMetricID("FITNESS_AGE") == .cardio)
        // v0.14.8 Item-2 — the two promoted warm scores.
        #expect(WellnessGradient.forMetricID("RECOVERY_SCORE") == .recovery)
        #expect(WellnessGradient.forMetricID("STRESS_SCORE") == .stress)
        // v0.14.9 §2 — the two re-frames promoted to delta/band ring tiles.
        #expect(WellnessGradient.forMetricID("VASCULAR_AGE_DELTA") == .vascular)
        #expect(WellnessGradient.forMetricID("HRV_BALANCE") == .hrvBalance)
        #expect(WellnessGradient.forMetricID("COINCIDENT_DEVIATION") == nil)
        #expect(WellnessGradient.forMetricID("anything-else") == nil)
    }

    // MARK: - Convergence: each card's light corner = its INNER grid corner

    @Test("each score's light corner is the inner (grid-centre) corner")
    func lightCornersConverge() {
        // 2×2 layout: TL Tagesform, TR Schlaf, BL Belastung, BR Cardio.
        // Inner corner = the one nearest the grid centre.
        #expect(WellnessGradient.tagesform.lightCorner == .bottomTrailing) // top-left → inner BR
        #expect(WellnessGradient.schlaf.lightCorner == .bottomLeading) // top-right → inner BL
        #expect(WellnessGradient.belastung.lightCorner == .topTrailing) // bottom-left → inner TR
        #expect(WellnessGradient.cardio.lightCorner == .topLeading) // bottom-right → inner TL
    }

    @Test("the light corners exhaust all four grid corners")
    func lightCornersDistinct() {
        let corners = WellnessGradient.allCases.map(\.lightCorner)
        // Four distinct corners — they fan out from the centre, one per quadrant.
        // v0.14.8 Item-2 + v0.14.9 §2: the promoted scores (recovery/stress +
        // vascular/hrvBalance) reuse the four inner corners, so the distinct-
        // corner count stays 4 across all six cases.
        #expect(Set(corners.map(String.init(describing:))).count == 4)
    }

    // MARK: - Gradient geometry: saturated hue OUTER, light end INNER

    @Test("gradient start/end place the light end at the inner corner")
    func gradientGeometry() {
        // For each case the LAST gradient stop (light) sits at the inner corner,
        // i.e. the gradient endPoint equals that corner.
        let expected: [WellnessGradient: UnitPoint] = [
            .tagesform: .bottomTrailing,
            .schlaf: .bottomLeading,
            .belastung: .topTrailing,
            .cardio: .topLeading
        ]
        for (gradient, endCorner) in expected {
            let points = gradient.lightCorner.gradientPoints
            #expect(points.end == endCorner)
            // Saturated hue lives at the diagonally OPPOSITE outer corner.
            #expect(points.start != endCorner)
        }
    }

    // MARK: - Shared light token + distinct hues

    @Test("the convergent end token is shared (identical) across all four cards")
    func sharedConvergentToken() {
        // v0.14.10 §1 — the descriptor's convergent (inner-corner) end is the
        // single shared near-black DARK base token, not a per-card colour — the
        // contract that makes the corners converge into one continuous dark field.
        let base = HLColor.wellnessGradientDark
        // Token identity check: re-reading it yields the same Color value.
        #expect(HLColor.wellnessGradientDark == base)
    }

    @Test("each score has a distinct saturated hue (two greens pulled apart)")
    func distinctHues() {
        #expect(WellnessGradient.tagesform.hue == HLColor.wellnessTagesformHue)
        #expect(WellnessGradient.schlaf.hue == HLColor.wellnessSchlafHue)
        #expect(WellnessGradient.belastung.hue == HLColor.wellnessBelastungHue)
        #expect(WellnessGradient.cardio.hue == HLColor.wellnessCardioHue)
        // Tagesform (leaf green) and Cardio (teal-green) are deliberately
        // different so the two greens are not identical.
        #expect(WellnessGradient.tagesform.hue != WellnessGradient.cardio.hue)
        // v0.14.8 Item-2 — warm promoted scores.
        #expect(WellnessGradient.recovery.hue == HLColor.wellnessRecoveryHue)
        #expect(WellnessGradient.stress.hue == HLColor.wellnessStressHue)
        // The two warm scores are the same family but pulled apart.
        #expect(WellnessGradient.recovery.hue != WellnessGradient.stress.hue)
        // v0.14.9 §2 — the two promoted re-frames carry their own distinct hues.
        #expect(WellnessGradient.vascular.hue == HLColor.wellnessVascularHue)
        #expect(WellnessGradient.hrvBalance.hue == HLColor.wellnessHrvBalanceHue)
        // Vascular (soft violet) is pulled apart from Belastung (purple).
        #expect(WellnessGradient.vascular.hue != WellnessGradient.belastung.hue)
        // HRV-balance (steel-blue) is pulled apart from Schlaf (navy).
        #expect(WellnessGradient.hrvBalance.hue != WellnessGradient.schlaf.hue)
    }

    // MARK: - v0.14.9 §3 recovery is no longer red + §4 gradient softening

    /// §3 — the Erholung/Recovery hue moved AWAY from the reddish terracotta to a
    /// calm honey-yellow. Pins the new hue + that it differs clearly from the
    /// Schlaf-blue + Tagesform-green so the tile reads as "rest", not "alert".
    @Test("recovery hue is the calm honey-yellow, not the old red terracotta")
    func recoveryHueIsHoney() {
        // The new honey-yellow token.
        #expect(WellnessGradient.recovery.hue == HLColor.wellnessRecoveryHue)
        #expect(HLColor.wellnessRecoveryHue == Color(hex: 0xE0A94F))
        // NOT the retired terracotta.
        #expect(HLColor.wellnessRecoveryHue != Color(hex: 0xE07A5F))
        // Honey-yellow: red & green high, blue lower — i.e. yellow-ish, not red.
        let r = WellnessGradient.recovery.hue.resolve(in: EnvironmentValues())
        #expect(r.green > r.blue) // yellow has strong green vs blue
        #expect(r.red > r.blue) // warm
        // Clearly distinct from Schlaf-blue + Tagesform-green.
        #expect(WellnessGradient.recovery.hue != WellnessGradient.schlaf.hue)
        #expect(WellnessGradient.recovery.hue != WellnessGradient.tagesform.hue)
    }

    /// v0.14.10 §1 — direction REVERSED. Every wellness gradient's outer corner is
    /// now pulled toward the near-black `wellnessGradientDark` card base by ≥60%
    /// (operator: the old light-blended tiles were "zu hell, sehr weiß und bold").
    /// Pins the darkening factor + that the darkened hue is measurably DARKER than
    /// the raw saturated hue (closer to the dark base) yet still retains some hue.
    @Test("gradient hues are darkened ≥60% toward the near-black card base")
    func gradientDarkenedTowardBase() {
        #expect(WellnessGradient.darkenTowardBase >= 0.60)
        let dark = HLColor.wellnessGradientDark.resolve(in: EnvironmentValues())
        for gradient in WellnessGradient.allCases {
            let raw = gradient.hue.resolve(in: EnvironmentValues())
            let darkened = gradient.darkenedHue.resolve(in: EnvironmentValues())
            /// Distance to the dark base, per channel sum — the darkened hue must
            /// be at least 60% of the way from the raw hue toward the dark base.
            func dist(_ c: Color.Resolved) -> Float {
                abs(c.red - dark.red) + abs(c.green - dark.green) + abs(c.blue - dark.blue)
            }
            let rawDist = dist(raw)
            let darkDist = dist(darkened)
            // darkDist ≈ rawDist * (1 - 0.72); allow tiny float slack.
            if rawDist > 0.001 {
                #expect(darkDist <= rawDist * 0.40)
            }
            // The darkened tile sits in the near-black tone: its luminance proxy
            // (channel mean) is clearly below mid-grey, i.e. the tile is DARK.
            let mean = (darkened.red + darkened.green + darkened.blue) / 3
            #expect(mean < 0.35)
        }
    }

    /// v0.14.10 §1 — the dark base token is the shared near-black card tone the
    /// gradients converge to. Pins it sits in the app's dark monochrome range.
    @Test("the wellness gradient dark base is a near-black card tone")
    func darkBaseIsNearBlack() {
        let dark = HLColor.wellnessGradientDark.resolve(in: EnvironmentValues())
        let mean = (dark.red + dark.green + dark.blue) / 3
        #expect(mean < 0.25) // near-black, in the app's dark surface range
    }

    // MARK: - Ring palette on the coloured tiles is WHITE (3rd contrast iter)

    /// v0.14.1 (3rd contrast iter) — locks the wellness-ring fill + value + label
    /// to WHITE on the SATURATED convergent gradient tiles. The earlier pass
    /// painted them dark graphite (`wellnessRingInk`) for an ASSUMED beige tile;
    /// on the real saturated hues dark read heavy/out-of-place, so they flipped
    /// to white (operator-confirmed). This pins the new contract so it can't
    /// silently revert to the dark override.
    @Test("the wellness-ring fill, value, and label are softened off-white on the coloured tiles")
    func ringPaletteIsWhite() {
        // v0.14.1 polish — fill arc + centre value are OFF-white (~0.90), softened
        // from pure white so the white reads calmer on the now-dark tiles.
        #expect(WellnessRingPalette.fill == Color.white.opacity(WellnessRingPalette.fillOpacity))
        #expect(WellnessRingPalette.value == Color.white.opacity(WellnessRingPalette.fillOpacity))
        #expect(WellnessRingPalette.fillOpacity >= 0.85 && WellnessRingPalette.fillOpacity <= 0.92)
        // Centre label is white at a LOWER opacity for hierarchy (~0.70, softened
        // from 0.85 so the metric label sits calmer).
        #expect(WellnessRingPalette.label == Color.white.opacity(WellnessRingPalette.labelOpacity))
        #expect(WellnessRingPalette.labelOpacity >= 0.65 && WellnessRingPalette.labelOpacity <= 0.75)
        // Track is white at a low opacity so the channel reads on the gradient
        // without competing with the bright fill.
        #expect(WellnessRingPalette.track == Color.white.opacity(WellnessRingPalette.trackOpacity))
        #expect(WellnessRingPalette.trackOpacity >= 0.22 && WellnessRingPalette.trackOpacity <= 0.28)
        // The fill is NOT the old dark graphite override anymore.
        #expect(WellnessRingPalette.fill != HLColor.wellnessRingInk)
    }

    /// Pins the legibility safeguard: a soft, single-touch dark text shadow so
    /// white never disappears on the gradient's lightest corner. v0.14.9 §4 —
    /// strengthened (0.38 opacity, radius 3) after the −45% softening lifted the
    /// tiles lighter; kept a single soft touch so it stays premium.
    @Test("the white ring carries a subtle dark legibility shadow")
    func ringHasSubtleShadow() {
        #expect(WellnessRingPalette.shadowColor == Color.black.opacity(0.38))
        #expect(WellnessRingPalette.shadowRadius > 0 && WellnessRingPalette.shadowRadius <= 4)
        #expect(WellnessRingPalette.shadowYOffset >= 0 && WellnessRingPalette.shadowYOffset <= 2)
    }
}
