@testable import HealthLog
import SwiftUI
import Testing

/// **v0152 T1 — locks the single-shipped-style tile-appearance contract.**
///
/// The b182 dev-switchable tile-style picker (thirteen concepts + an `@AppStorage`
/// override) was the ONE hard App-Store review blocker (dev UI in Release). The
/// operator picked **P9 · `prismUniform`** as the final look, so the picker, its
/// pref key, and the other twelve concepts were deleted. `InsightsTileStyle` now
/// has exactly one case and every tile renders P9 unconditionally.
///
/// These pin the resulting appearance so a refactor can't silently revert it: P9
/// rides on a flat MONO surface (appearance-AWARE backing → the default ring fill
/// stays legible in BOTH schemes, no invisible arc), draws NO cap dot, and is the
/// only style there is. Pure value-object checks — no SwiftUI host.
@Suite("Insights tile appearance — single shipped style (P9)")
struct InsightsTileAppearanceTests {
    /// The enum has collapsed to exactly one case — there is no longer any way to
    /// pick a different tile style (the App-Store ship blocker is gone).
    @Test("the tile style is always prismUniform — no picker, no other case")
    func tileStyleIsAlwaysPrismUniform() {
        #expect(InsightsTileStyle.allCases == [.prismUniform])
        #expect(InsightsTileStyle.shippingDefault == .prismUniform)
    }

    /// The shipping default (P9 `prismUniform`) is a flat MONO surface, so the live
    /// Insights ring renders on an appearance-AWARE backing where the default fill
    /// is legible in BOTH schemes (no invisible arc for any user). The prism rides
    /// on TOP as a decorative effect; the surface keeps the nil (appearance-aware)
    /// default fill and needs no legibility shadow.
    @Test("P9 is an appearance-aware mono surface with the default ring fill")
    func prismUniformIsAppearanceAwareMono() {
        let appearance = InsightsTileStyle.prismUniform.appearance(signal: .ok)
        #expect(appearance.surface == .mono)
        #expect(!appearance.usesGradientInk)
        #expect(appearance.ringFill == nil)
        #expect(!appearance.ringShadowActive)
    }

    /// P9 carries the uniform prism effect over the mono surface AND draws NO cap
    /// dot — the operator asked for "kein Punkt vorne im Kreis". The signal passed
    /// in is irrelevant: the cap dot is always suppressed.
    @Test("P9 applies the uniform prism effect and never draws a cap dot")
    func prismUniformHasNoCapDot() {
        for signal: HLScoreRing.HLSignal? in [.ok, .warn, .bad, nil] {
            let appearance = InsightsTileStyle.prismUniform.appearance(signal: signal)
            #expect(appearance.ringEffect == .prismUniform)
            #expect(appearance.ringSignal == nil)
        }
    }

    /// The white palette fill is NOT the dark-mode-flipping `HLChartTints.series`
    /// default — pinned so a future gradient-surface reintroduction can't collapse
    /// the two and resurrect the invisible-arc bug.
    @Test("the white ring palette is distinct from the dark-mode-flipping default")
    func whitePaletteIsNotTheFlippingDefault() {
        #expect(WellnessRingPalette.fill != HLChartTints.series)
    }
}
