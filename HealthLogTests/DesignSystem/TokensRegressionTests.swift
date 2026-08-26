@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// Anchors the design-token surface so accidental rename / removal in Tokens.swift
/// fails the build instead of silently breaking call-sites across the screen
/// library. Pure value assertions — no rendering — so they're sub-millisecond
/// and trivially deterministic.
@Suite("Tokens regression")
struct TokensRegressionTests {
    @Test("Semantic v0.4.0 radius aliases are present and HIG-aligned")
    func radiusAliasesPresent() {
        // The named radii are referenced by downstream Echo components +
        // every B-stream tile/card/sheet. Removing or renaming silently
        // breaks every consumer.
        #expect(HLRadius.tile == 16)
        #expect(HLRadius.card == 20)
        #expect(HLRadius.button == 14)
        #expect(HLRadius.sheet == 28)
    }

    @Test("Sheet detents default to .large only (sheet-glitch fix anchor)")
    func sheetDetentsLargeOnly() {
        // Per A6 §5 + user-report #4 — the v0.4.0 capture sheet presents at
        // .large only to avoid the keyboard-promotion glitch. Regression
        // guard: a future "add medium back" would re-introduce the half-open
        // animation.
        #expect(HLSheet.detents == [.large])
    }

    @Test("Sheet focus delay is 600ms (real-device focus-after-present anchor)")
    func sheetFocusDelay() {
        // PA8 audit (v0.5.0+): 350ms was simulator-tuned and fired focus
        // mid-flight on real ProMotion devices, reproducing the half-open
        // glitch of User-Report #4 despite the v0.4.0 detent fix. 600ms
        // covers Apple's spring-settle window on real iPhone 16 Pro
        // (~400-550ms) with comfortable head-room. Below ~600ms the
        // keyboard rise fights the present animation again.
        #expect(HLSheet.focusDelay == .milliseconds(600))
    }

    @Test("Chart style heights are non-zero + ordered")
    func chartHeightsOrderly() {
        // Compact (sparkline) < detail (drill-down) ≤ emoji-axis (mood).
        // Encodes the visual hierarchy commitment.
        #expect(HLChartStyle.heightCompact > 0)
        #expect(HLChartStyle.heightDetail > HLChartStyle.heightCompact)
        #expect(HLChartStyle.heightEmojiAxis >= HLChartStyle.heightDetail)
    }

    @Test("Opacity tokens are within 0…1 and ordered")
    func opacityWellFormed() {
        for opacity in [
            HLOpacity.surfaceTintWeak,
            HLOpacity.surfaceTintStrong,
            HLOpacity.disabled,
            HLOpacity.locked
        ] {
            #expect((0.0 ... 1.0).contains(opacity))
        }
        // Strong tint > weak tint (semantic: "strong" should visibly outweigh "weak").
        #expect(HLOpacity.surfaceTintStrong > HLOpacity.surfaceTintWeak)
    }

    @Test("Color aliases route to the canonical asset tokens")
    func colorAliasesRouteCorrectly() {
        // These are pure aliases — verifying their existence and that they
        // compile is sufficient. We can't compare SwiftUI Colors for
        // equality (no Equatable on the underlying provider), so we just
        // touch each to keep them in the public surface.
        let aliases: [Color] = [
            .hlBackground, .hlBackgroundElevated, .hlSurface, .hlSurfaceElevated
        ]
        #expect(aliases.count == 4)
    }

    // MARK: - Dracula palette contract (PA1 audit, locked 2026-05-15)

    //
    // Pixel-exact mapping between iOS brand tokens and the canonical web
    // Dracula palette (`globals.css:109-134`). Locks the v0.4.1 regression
    // (de-saturated cyan/green + Radix-tuned status colours) out of the
    // codebase. If web changes its Dracula hex, fix here too — handoff
    // §1.4 is single source of truth.

    @Test("Brand tokens match canonical Dracula hex")
    @MainActor
    func brandTokensMatchDracula() {
        // v0.14 purple-sweep: `HLColor.purple` / `.pink` / `.lavender` were
        // deleted (HealthLog is monochrome-graphite — no purple/pink renders
        // anywhere). The surviving Dracula tokens (status/signal hues) stay
        // pixel-locked to the canonical web palette.
        #expect(TokensRegressionTests.hex(of: HLColor.cyan) == 0x8BE9FD)
        #expect(TokensRegressionTests.hex(of: HLColor.green) == 0x50FA7B)
        #expect(TokensRegressionTests.hex(of: HLColor.orange) == 0xFFB86C)
        #expect(TokensRegressionTests.hex(of: HLColor.red) == 0xFF5555)
        #expect(TokensRegressionTests.hex(of: HLColor.yellow) == 0xF1FA8C)
    }

    @Test("Status traffic-light is dual-appearance: light-tuned + Dracula dark")
    @MainActor
    func statusTokensRouteToDracula() {
        // W-LIGHT (v0.8.0) — status colours promoted from single `Color(hex:)`
        // literals to dual-appearance colorsets. The DARK slot keeps the exact
        // Dracula `--success`/`--warning`/`--destructive` hex
        // (`globals.css:185-187`). The Any/LIGHT slot was retuned in the
        // v0.14.11 "Warmes Papier" redesign to deep, low-chroma signal tones
        // (#2B774B / #9B5D10 / #B23E3B) that clear WCAG AA 4.5:1 on the warm
        // card AND canvas (the prior #1F8A4C green @4.1:1 and #C8761E amber
        // @3.3:1 both failed AA text). Asserting both slots so neither an
        // accidental re-neon of light nor a drift of the dark Dracula values
        // slips in unnoticed.
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        // Light — calm-on-white.
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusOK, traits: light) == 0x2B774B)
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusWarn, traits: light) == 0x9B5D10)
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusBad, traits: light) == 0xB23E3B)

        // Dark — unchanged Dracula.
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusOK, traits: dark) == 0x50FA7B)
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusWarn, traits: dark) == 0xFFB86C)
        #expect(TokensRegressionTests.resolvedHex(of: HLColor.statusBad, traits: dark) == 0xFF5555)
    }

    @Test("Theme-2.0 final: passive card surface resolves to operator-locked mono")
    @MainActor
    func categoryTintsCollapseToMonoSurface() {
        // T2-5 final (2026-05-16) — the legacy `HLColor.dashboardCategory*`
        // namespace was deleted once T2-2 swept `MetricKindDescriptor.tint`
        // onto `HLSurface.secondary`. This test used to assert each legacy
        // token resolved to mono; now it asserts the consumer-side invariant:
        // the single token every passive card surface routes through resolves
        // to the operator-locked white / lifted-charcoal hex, so a future
        // asset-catalog edit drifting the family-grouped hue back in fails the
        // build the same way the legacy assertion did.
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.secondary, traits: lightTraits) == 0xFAF8F5)
        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.secondary, traits: darkTraits) == 0x1A1B1F)
    }

    @Test("C-8 canonical Dracula background token exists and is off by default")
    @MainActor
    func canonicalDraculaBackgroundIsOperatorFlippableDefaultOff() {
        // R1 Strategy C / C-8 — the canonical web Dracula `#282A36` is now
        // exposed as a first-class iOS token so a future flip is purely
        // token-layer. Default-off until operator's felt-walkthrough on
        // real hardware sign-off.
        //
        // Lock both invariants:
        //   1. The hex token resolves to canonical Dracula `#282A36`.
        //   2. The flip is `false` so the asset-catalog `Background`
        //      (`#16171C` dark, `#F5F5F8` light) still ships unchanged.
        //   3. `canvasBackground` therefore routes to the asset-catalog
        //      surface, *not* to the canonical hex.
        #expect(TokensRegressionTests.hex(of: HLColor.surfaceCanonicalDracula) == 0x282A36)
        #expect(HLColor.useCanonicalDraculaBackground == false)

        // Asset-catalog Background dark stays at v0.4.0 §A6 retune (#16171C).
        // Resolve the SwiftUI alias against an explicit dark trait collection
        // so the test doesn't depend on the simulator's interface style.
        let darkBackground = UIColor(HLColor.background)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        #expect(darkBackground.getRed(&r, green: &g, blue: &b, alpha: &a))
        let resolved = (UInt32((r * 255).rounded()) & 0xFF) << 16
            | (UInt32((g * 255).rounded()) & 0xFF) << 8
            | (UInt32((b * 255).rounded()) & 0xFF)
        #expect(resolved == 0x16171C)

        // `canvasBackground` mirrors `background` while the flip is off —
        // resolve the same way to lock in the chokepoint behaviour.
        let canvas = UIColor(HLColor.canvasBackground)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var cr: CGFloat = 0
        var cg: CGFloat = 0
        var cb: CGFloat = 0
        var ca: CGFloat = 0
        #expect(canvas.getRed(&cr, green: &cg, blue: &cb, alpha: &ca))
        let canvasHex = (UInt32((cr * 255).rounded()) & 0xFF) << 16
            | (UInt32((cg * 255).rounded()) & 0xFF) << 8
            | (UInt32((cb * 255).rounded()) & 0xFF)
        #expect(canvasHex == 0x16171C)
    }

    // MARK: - Theme-2.0 Tonal-Mono surface + text scale (T2-1 Foundation)

    //
    // Operator-locked hex for the Withings-Style rework. Light surface starts
    // at warm-grey `#F7F7F8` (never pure white); dark surface at deep-charcoal
    // `#101113` (never pure black). Text scale at hi-contrast primary with
    // derived 70% / 40% opacity for secondary / tertiary. Assertions resolve
    // the asset-catalog tokens in both trait collections so a hex drift in
    // either light or dark surfaces fails the build.

    @Test("Theme-2.0 surface tokens resolve to operator-locked light/dark hex")
    @MainActor
    func theme2SurfaceTokensResolveCorrectly() {
        // v0.14.11 "Warmes Papier" light redesign — light elevation is a
        // lightness ladder inside one warm-paper family, never pure white for
        // cards. Light: #F2F0EB (paper canvas) / #FAF8F5 (warm near-white
        // card) / #E9E6E0 (recessed well); pure #FFFFFF is reserved for
        // SurfaceElevated (top tier). Dark slots UNCHANGED: #101113 / #1A1B1F
        // / #25262B (canvas / card / recessed).
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.primary, traits: lightTraits) == 0xF2F0EB)
        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.primary, traits: darkTraits) == 0x101113)

        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.secondary, traits: lightTraits) == 0xFAF8F5)
        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.secondary, traits: darkTraits) == 0x1A1B1F)

        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.tertiary, traits: lightTraits) == 0xE9E6E0)
        #expect(TokensRegressionTests.resolvedHex(of: HLSurface.tertiary, traits: darkTraits) == 0x25262B)
    }

    @Test("v0.8.1: chrome accent routes to monochrome HLText.primary")
    @MainActor
    func theme2AccentRoutesToMonochrome() {
        // v0.8.1 monochrome-restore — `HLAccent.primary` was locked to
        // Dracula-Purple `#BD93F9`, which (via the W6 chrome sweep + retired
        // accent-picker) painted the Settings hub, list-row chips, badges and
        // achievement art purple. The operator's direction is "chrome =
        // monochrome, accent is signal-only", so `primary` now resolves to the
        // monochrome `HLText.primary` (`#2E2B27` light / `#EBEBF5` dark). This
        // lock is deliberately re-pointed to the monochrome target so a future
        // rollback re-introducing purple chrome fails the build.
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.primary, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.primary, traits: darkTraits) == 0xEBEBF5)
        // `userBrandTint` (the chrome chokepoint the W6 sweep routed through)
        // resolves to the same monochrome value.
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.userBrandTint, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.userBrandTint, traits: darkTraits) == 0xEBEBF5)
        // v0.8.2 W3a/A3 monochrome-restore: the pressed-state variant was the
        // Dracula-Purple `#7C5CD8`, which would flash a stray purple on an
        // otherwise monochrome button press. It now resolves to a dimmed
        // `HLText.primary` (same monochrome RGB as `primary`, alpha knocked
        // down by 0.7) so the press state stays monochrome. Lock both the RGB
        // (== primary) and the dimmed alpha so a rollback to purple fails.
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.pressed, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.pressed, traits: darkTraits) == 0xEBEBF5)
        // primary light alpha 0.90 × 0.7 = 0.63 → 0.6; dark 1.0 × 0.7 = 0.7.
        #expect(TokensRegressionTests.resolvedAlpha(of: HLAccent.pressed, traits: lightTraits) == 0.6)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLAccent.pressed, traits: darkTraits) == 0.7)
    }

    @Test("Theme-2.0 text tokens resolve to hi-contrast primary plus opacity ramp")
    @MainActor
    func theme2TextTokensResolveCorrectly() {
        // v0.14.11 "Warmes Papier" light redesign — the light ramp is ONE warm
        // ink #2E2B27 at three opacities (0.90 / 0.72 / 0.50), mirroring the
        // dark #EBEBF5 @ 1.0/0.7/0.4 ramp. The old ramp was broken at both
        // ends: primary #1C1C1E@0.9 on pure white hit a harsh 12.6:1 while
        // secondary #3C3C43@0.6 FAILED WCAG AA at 3.4:1. New effective ratios
        // on the #FAF8F5 card: ~9.8:1 / ~5.6:1 / ~2.9:1. Dark slot
        // (#EBEBF5 at full / 0.70 / 0.40) is UNCHANGED.
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

        #expect(TokensRegressionTests.resolvedHex(of: HLText.primary, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLText.primary, traits: darkTraits) == 0xEBEBF5)
        #expect(TokensRegressionTests.resolvedAlpha2(of: HLText.primary, traits: lightTraits) == 0.9)

        #expect(TokensRegressionTests.resolvedHex(of: HLText.secondary, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedAlpha2(of: HLText.secondary, traits: lightTraits) == 0.72)
        #expect(TokensRegressionTests.resolvedHex(of: HLText.tertiary, traits: lightTraits) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedAlpha2(of: HLText.tertiary, traits: lightTraits) == 0.5)

        // Dark slot unchanged: off-white #EBEBF5, secondary 0.70 / tertiary 0.40.
        #expect(TokensRegressionTests.resolvedAlpha(of: HLText.secondary, traits: darkTraits) == 0.7)
        #expect(TokensRegressionTests.resolvedHex(of: HLText.tertiary, traits: darkTraits) == 0xEBEBF5)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLText.tertiary, traits: darkTraits) == 0.4)
    }

    @Test("v0.8.1: chart-series ramp routes every tier through monochrome HLText.primary")
    @MainActor
    func theme2ChartSeriesRampRoutesThroughMono() {
        // v0.8.1 monochrome-restore — chart series previously followed the
        // persisted accent pick (default Dracula-Purple), which painted every
        // chart line purple now that the accent-picker UI is retired. Per the
        // monochrome direction, series now resolve to a single mono ink (v0.14:
        // `HLColor.inkGraphite`, which is dark-identical to `HLText.primary` at
        // `#EBEBF5`) and no longer read the persisted tint. Resolve against an
        // explicit dark trait (where the ink is full-opacity `#EBEBF5`) so the
        // 100%/70%/40% ramp is clean and deterministic; the v0.14 graphite
        // softening only diverges from text ink in LIGHT mode (asserted in
        // `chartSeriesTintsCollapseToSingleAccent`), so the dark ramp is stable.
        TokensRegressionTests.resetPreferredTint()
        let darkT = UITraitCollection(userInterfaceStyle: .dark)

        // Monochrome hue in dark: off-white #EBEBF5 at every tier.
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.series, traits: darkT) == 0xEBEBF5)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.seriesMid, traits: darkT) == 0xEBEBF5)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.seriesLow, traits: darkT) == 0xEBEBF5)

        // Opacity ramp: 100% / 70% / 40% (dark base is full-opacity).
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.series, traits: darkT) == 1.0)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.seriesMid, traits: darkT) == 0.7)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.seriesLow, traits: darkT) == 0.4)

        // Threshold overlays — dashed-red high + dashed-green low, now routed
        // through the dual-appearance `statusBad` / `statusOK` colorsets
        // (W-LIGHT v0.8.0) so the dashed rules de-neon on white in light mode
        // while keeping the Dracula red/green in dark. The dashed stroke style
        // separates them visually from any solid status pill.
        let lightT = UITraitCollection(userInterfaceStyle: .light)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.thresholdHigh, traits: lightT) == 0xB23E3B)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.thresholdLow, traits: lightT) == 0x2B774B)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.thresholdHigh, traits: darkT) == 0xFF5555)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.thresholdLow, traits: darkT) == 0x50FA7B)
    }

    @Test("V052-R1: multi-series companions are graphite shades (collision-free)")
    @MainActor
    func multiSeriesCompanionsAreGraphite() {
        TokensRegressionTests.resetPreferredTint()
        // V052-R1 reconcile (2026-05-17) — Visual-Polish-1 shipped a fixed
        // 4-tint Dracula palette but operator design-QA on v0.5.2 caught a
        // regression: when the user-picked accent collides with one of the
        // Dracula companions (e.g. `.cyan` accent → weight series cyan AND
        // BP series cyan), two overlaid metrics collapsed onto the same hue.
        //
        // The new contract: lead series follows user-picked accent.
        // Companions paint in a monochrome graphite ramp derived from
        // `HLText.primary` at three opacities (~0.80 / ~0.55 / ~0.35) so
        // the accent line always reads as the headline and companions
        // stay distinct from the accent regardless of pick.
        //
        // Note: alpha extraction round-trips through UIColor → display-P3
        // and quantises to ~0.05 steps, so we assert with a tolerance
        // wide enough to survive the colour-space coercion but tight
        // enough to catch an intentional ramp-step refactor.
        // v0.8.1: resolve against dark traits where `HLText.primary` is
        // full-opacity, so the companion ramp scales cleanly off 1.0 (in light
        // mode the alpha-over-surface base 0.90 would scale the whole ramp).
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        let alt1Alpha = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.seriesAlt1, traits: darkT)
        let alt2Alpha = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.seriesAlt2, traits: darkT)
        let alt3Alpha = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.seriesAlt3, traits: darkT)

        // Companion ramp steps — Tokens.swift sets 0.80 / 0.55 / 0.35;
        // UIColor round-trip lands in [0.78..0.82] / [0.55..0.60] / [0.30..0.36].
        #expect(abs(alt1Alpha - 0.80) < 0.05)
        #expect(abs(alt2Alpha - 0.575) < 0.05)
        #expect(abs(alt3Alpha - 0.325) < 0.05)

        // Lightness is monotonically decreasing — every step is distinct.
        #expect(alt1Alpha > alt2Alpha)
        #expect(alt2Alpha > alt3Alpha)

        // Bottom of the ramp must still sit clearly above the gridline
        // noise floor (`HLChartGrid.lineOpacity` = 0.10) so the dimmest
        // companion never disappears into the chart background.
        #expect(alt3Alpha > HLChartGrid.lineOpacity)
    }

    @Test("V052-R1: multiSeriesRamp orders accent → alt1 → alt2 → alt3")
    @MainActor
    func multiSeriesRampOrderIsDeterministic() {
        TokensRegressionTests.resetPreferredTint()
        // Consumers (`TrendsOverlayCard`) index into `multiSeriesRamp` by
        // metric position so the same metric always renders in the same
        // visual lane (accent / 0.80-graphite / 0.55-graphite / 0.35-graphite).
        // Lock the ramp order so a reordering doesn't silently re-paint
        // every existing series.
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        #expect(HLChartTints.multiSeriesRamp.count == 4)
        // v0.8.1: index 0 = monochrome lead series (`HLText.primary`), no
        // longer the user-picked accent — off-white #EBEBF5 in dark.
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.multiSeriesRamp[0], traits: darkT) == 0xEBEBF5)
        // Indices 1..3 = graphite companions, monotonically decreasing alpha.
        let a1 = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.multiSeriesRamp[1], traits: darkT)
        let a2 = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.multiSeriesRamp[2], traits: darkT)
        let a3 = TokensRegressionTests.resolvedAlpha2(of: HLChartTints.multiSeriesRamp[3], traits: darkT)
        #expect(abs(a1 - 0.80) < 0.05)
        #expect(abs(a2 - 0.575) < 0.05)
        #expect(abs(a3 - 0.325) < 0.05)
        #expect(a1 > a2)
        #expect(a2 > a3)
    }

    @Test("Theme-2.0 chart-grid tokens encode ultra-subtle Withings treatment")
    func theme2ChartGridIsSubtle() {
        // Operator spec: grid ~10% primary-text opacity, no chunky lines.
        // Threshold dash pattern is `[4, 3]` so dashes stay discrete at the
        // 80pt compact tile height through 220pt emoji-axis height.
        #expect(HLChartGrid.lineOpacity == 0.10)
        #expect(HLChartGrid.lineWidth == 0.5)
        #expect(HLChartGrid.labelOpacity == 0.40)
        #expect(HLChartGrid.thresholdDash == [4, 3])
        #expect(HLChartGrid.thresholdWidth == 1.5)
        // Threshold rule (1.5pt) is heavier than gridline (0.5pt) but still
        // thinner than the primary LineMark (`HLChartStyle.lineWidth = 2`).
        #expect(HLChartGrid.thresholdWidth < HLChartStyle.lineWidth)
        #expect(HLChartGrid.thresholdWidth > HLChartGrid.lineWidth)
    }

    @Test("v0.14: chart-series is refined graphite, chrome accent stays HLText.primary")
    @MainActor
    func chartSeriesTintsCollapseToSingleAccent() {
        TokensRegressionTests.resetPreferredTint()
        // v0.8.1 monochrome-restore — the two semantic anchors the production
        // code routes through, chart-data (`HLChartTints.series`) and
        // active/selected (`HLAccent.primary`), previously both resolved to
        // Dracula-Purple `#BD93F9`, then both to the monochrome `HLText.primary`.
        //
        // v0.14 light-mode walk — chart data-ink (`HLChartTints.series`) is
        // repointed to the softer `HLColor.inkGraphite` (v0.14.11 "Warmes
        // Papier": warm graphite `#454138` light) so charts + rings read as
        // refined graphite rather than the near-black text ink. Dark mode is unchanged (`inkGraphite`
        // dark == `HLText.primary` dark == `#EBEBF5`). Chrome accent
        // (`HLAccent.primary`) stays on `HLText.primary` (text-parity). This
        // locks both: a purple rollback OR a chart-ink/text-ink remerge fails.
        let lightT = UITraitCollection(userInterfaceStyle: .light)
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.series, traits: lightT) == 0x454138)
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.series, traits: darkT) == 0xEBEBF5)
        // Chart ink is now deliberately distinct from text ink in light mode.
        #expect(TokensRegressionTests.resolvedHex(of: HLChartTints.series, traits: lightT)
            != TokensRegressionTests.resolvedHex(of: HLText.primary, traits: lightT))
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.primary, traits: lightT) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.primary, traits: darkT) == 0xEBEBF5)
        // v0.8.2 W3a/A3: pressed-state variant is now a dimmed monochrome
        // `HLText.primary` (was `purpleDeep` `#7C5CD8`) so the press flash
        // stays monochrome. RGB == primary; alpha knocked down by 0.7.
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.pressed, traits: lightT) == 0x2E2B27)
        #expect(TokensRegressionTests.resolvedHex(of: HLAccent.pressed, traits: darkT) == 0xEBEBF5)
    }

    // MARK: - Helpers

    /// Decodes a SwiftUI `Color` constructed in the sRGB colour-space back into
    /// its 24-bit RGB hex representation. Only valid for colours initialised
    /// via `Color(.sRGB, red:green:blue:opacity:)` — which is exactly how the
    /// `Color(hex:)` initialiser in `Tokens.swift` does it.
    @MainActor
    static func hex(of color: Color) -> UInt32 {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let uiColor = UIColor(color)
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        let rb = UInt32((r * 255).rounded()) & 0xFF
        let gb = UInt32((g * 255).rounded()) & 0xFF
        let bb = UInt32((b * 255).rounded()) & 0xFF
        return (rb << 16) | (gb << 8) | bb
    }

    /// Resolves an asset-catalog-backed SwiftUI `Color` against an explicit
    /// `UITraitCollection` and returns the 24-bit RGB hex. Use this for
    /// Theme-2.0 surface / text assertions so the test is deterministic
    /// regardless of the simulator's interface style.
    @MainActor
    static func resolvedHex(of color: Color, traits: UITraitCollection) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        let rb = UInt32((r * 255).rounded()) & 0xFF
        let gb = UInt32((g * 255).rounded()) & 0xFF
        let bb = UInt32((b * 255).rounded()) & 0xFF
        return (rb << 16) | (gb << 8) | bb
    }

    /// Resolves the alpha channel of an asset-catalog-backed `Color` against an
    /// explicit trait collection. Rounded to one decimal so the 0.7 / 0.4
    /// opacity-ramp assertions don't fight CGFloat precision.
    @MainActor
    static func resolvedAlpha(of color: Color, traits: UITraitCollection) -> Double {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return (a * 10).rounded() / 10
    }

    /// Resolves the alpha channel rounded to TWO decimals. The one-decimal
    /// `resolvedAlpha` can't distinguish the W-LIGHT light-mode ladder steps
    /// (0.62 / 0.36) from the prior 0.70 / 0.40, so the W-LIGHT light-ramp
    /// assertions use this higher-resolution variant.
    @MainActor
    static func resolvedAlpha2(of color: Color, traits: UITraitCollection) -> Double {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return (a * 100).rounded() / 100
    }

    /// Reads the alpha channel of a static (non-asset-catalog) `Color` such
    /// as `HLColor.purple.opacity(0.7)`. Rounded to one decimal to absorb
    /// CGFloat precision drift across translations.
    @MainActor
    static func alpha(of color: Color) -> Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return (a * 10).rounded() / 10
    }

    /// UX-H3 reconcile: clear the picker preference so the default
    /// (Dracula-Purple) takes effect for tests that assert factory tints.
    /// Mutates `UserDefaults.standard` — every test that depends on a known
    /// picker state must call this first.
    static func resetPreferredTint() {
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
    }
}

/// v0.8.1 monochrome-restore — `HLChartTints` previously resolved through the
/// user-picked accent (`SettingsStore.preferredTint`). Since the accent-picker
/// UI was retired in v0.6.1.0, that defaulted to purple, painting every chart
/// line purple. Chart series are now pinned to the monochrome `HLText.primary`
/// and ignore the persisted pick entirely. This suite locks the new
/// invariant: a persisted tint must NOT bleed back into chart chrome.
@Suite("HLChartTints monochrome-restore — v0.8.1")
struct HLChartTintsMonochromeTests {
    @Test("series ignores the persisted pick and stays monochrome")
    @MainActor
    func seriesStaysMonochromeAcrossPersistedPicks() {
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        // The legacy accent-swatch raw-values that could still sit in a
        // migrating user's `hl.settings.tint` key (the picker + `HLTint` enum
        // were removed in v0.17). None may bleed back into chart chrome.
        let legacyPicks = ["purple", "cyan", "pink", "orange", "green", "systemBlue", "schwarz", "weiss"]
        for picked in legacyPicks {
            UserDefaults.standard.set(picked, forKey: "hl.settings.tint")
            // Regardless of any persisted pick, the chart series resolves to
            // the monochrome off-white #EBEBF5 in dark — never the picked hue.
            #expect(
                TokensRegressionTests.resolvedHex(of: HLChartTints.series, traits: darkT) == 0xEBEBF5,
                "HLChartTints.series must stay monochrome despite persisted tint .\(picked)"
            )
        }
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
    }

    @Test("seriesMid + seriesLow opacity ramp persists across persisted picks")
    @MainActor
    func opacityRampStableAcrossPersistedPicks() {
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        UserDefaults.standard.set("cyan", forKey: "hl.settings.tint")
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.series, traits: darkT) == 1.0)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.seriesMid, traits: darkT) == 0.7)
        #expect(TokensRegressionTests.resolvedAlpha(of: HLChartTints.seriesLow, traits: darkT) == 0.4)
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
    }

    @Test("multiSeriesRamp[0] stays monochrome — companion slots stay graphite")
    @MainActor
    func multiSeriesRampHeadStaysMonochrome() {
        let darkT = UITraitCollection(userInterfaceStyle: .dark)
        UserDefaults.standard.set("orange", forKey: "hl.settings.tint")
        let ramp = HLChartTints.multiSeriesRamp
        #expect(ramp.count == 4)
        // Head no longer tracks the picker — it is the monochrome lead series.
        #expect(TokensRegressionTests.resolvedHex(of: ramp[0], traits: darkT) == 0xEBEBF5)
        // Companions stay graphite shades derived from `HLText.primary`. Alpha
        // tolerance covers UIColor display-P3 round-trip quantisation.
        let a1 = TokensRegressionTests.resolvedAlpha(of: ramp[1], traits: darkT)
        let a2 = TokensRegressionTests.resolvedAlpha(of: ramp[2], traits: darkT)
        let a3 = TokensRegressionTests.resolvedAlpha(of: ramp[3], traits: darkT)
        #expect(abs(a1 - 0.80) < 0.05)
        #expect(abs(a2 - 0.575) < 0.06)
        #expect(abs(a3 - 0.325) < 0.05)
        #expect(a1 > a2)
        #expect(a2 > a3)
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
    }
}
