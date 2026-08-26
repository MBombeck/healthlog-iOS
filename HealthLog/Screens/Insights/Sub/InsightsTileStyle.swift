import SwiftUI

/// **The Insights score-tile style — now a single shipped concept (P9).**
///
/// **v0152 T1 (ship blocker)** — the b182 dev-switchable tile-style picker was an
/// internal-only affordance (a runtime `Picker` over thirteen concepts) that the
/// App-Store production-readiness audit flagged as the ONE hard review blocker
/// (dev UI in a Release build). The operator picked **P9 · `prismUniform`** as the
/// final look, so the picker, its `@AppStorage` override, and the other twelve
/// concepts were deleted. Every tile now renders P9 unconditionally — there is no
/// user pref, no dev surface, nothing to gate before submit.
///
/// The style ONLY changes the leaf-tile *surface* + how the ring is coloured —
/// the data plumbing (`tiles`/`Tile`, `ringPromotedIDs`, gates, a11y) and the
/// `HLScoreRing` internals are untouched. The single case resolves to an
/// ``InsightsTileAppearance`` that the surface helper + the ring cards consume.
///
/// - **P9** `prismUniform` — a pure-SwiftUI `MeshGradient` spectral wash masked
///   STRICTLY to the FILLED arc (`0…fraction`) plus a subtle STEADY glow on that
///   arc. NO Metal, NO `.layerEffect` — renders identically on every tile (hero +
///   small) on device AND in the Simulator, with no cap dot. Reduce-motion /
///   Low-Power → the glow drops to its static still frame.
enum InsightsTileStyle: String, CaseIterable, Identifiable {
    case prismUniform // P9 (W-B190 — pure-SwiftUI arc-masked prism + steady glow, ALL tiles, no Metal, no cap dot)

    var id: String {
        rawValue
    }

    /// The sole shipped style. Every Insights tile renders P9 — there is no
    /// user-facing or dev-facing way to change it (v0152 T1 removed the picker).
    static let shippingDefault: InsightsTileStyle = .prismUniform

    /// The render appearance for this style + the metric's signal. Centralises
    /// every per-style surface/ring decision so the ring cards stay branch-free
    /// (they just pass `signal`).
    func appearance(signal: HLScoreRing.HLSignal?) -> InsightsTileAppearance {
        InsightsTileAppearance(style: self, signal: signal)
    }
}

/// **The resolved per-tile render appearance for an ``InsightsTileStyle``.**
///
/// One value object the ring cards read so the style branch lives in exactly one
/// place. It decides (a) the surface kind, (b) whether the ring draws a single
/// signal cap dot, (c) the ring fill/track/ink colours (mono → `nil` overrides
/// keep the primitive's appearance-aware default), and (d) whether the legibility
/// shadow is active (only the warm-gradient surface needs it).
struct InsightsTileAppearance {
    enum Surface: Equatable {
        /// Flat `HLCard` mono surface (A + the ring-effect concepts P1/P2/P3/P5x).
        case mono
        /// Liquid Glass surface on iOS 26+, flat fallback on 18–25 (C).
        case glass
        /// One shared neutral warm gradient on every tile (F).
        case restrainedGradient
        /// Native iOS-26 `glassEffect` on the tile SURFACE inside a
        /// `GlassEffectContainer` (P4 `glassTile`); `.ultraThinMaterial` fallback
        /// on iOS 18–25. The ring stays a crisp gradient stroke on top (HIG —
        /// glass on the surface, never on the data ring stroke).
        case glassTile
    }

    /// **b182 — the optical/motion treatment layered over the `HLScoreRing`.**
    ///
    /// Orthogonal to `Surface`: the surface decides the card chrome, the
    /// `ringEffect` decides what rides on top of the ring (a prism rim, a
    /// specular glint, a score-reactive bloom, or the experimental Metal rim
    /// shader). `none` keeps the plain ring (A / C / F). Applied by exactly one
    /// shared modifier (`.insightsRingEffect`) so every ring card stays branch-
    /// free. Every effect has a defined reduce-motion still + a Low-Power cheap
    /// path inside its view.
    enum RingEffect: Equatable {
        case none
        /// P1 — `AngularGradient` spectrum stroked on the rim, `.plusLighter`,
        /// masked thin, slowly hue-cycled. Jank-free, safe on all tiles.
        case prismOverlay
        /// P2 / P7 / P8 — one-shot bright specular glint glides the fill arc on
        /// value-land. `dimmed` applies the ~12 % tile-local dim the operator asked
        /// for (P2/P7/P8 all run dimmed). `tint` carries the metric's signal so the
        /// glint can read as a green/amber/red sheen (P8); `nil` keeps it mono
        /// (P2/P7). The dot vs no-dot difference lives in `ringSignal`, not here.
        case specularSweep(dimmed: Bool, tint: HLScoreRing.HLSignal?)
        /// P3 — `HLBloomHalo` behind the arc head, intensity mapped to the score.
        case scoreBloom
        /// P5x — EXPERIMENTAL real Metal `.layerEffect` chromatic rim shader, the
        /// chromatic break-up masked to the FILLED arc (0…fraction) only.
        case prismShader
        /// P5b — P5's chromatic prism PLUS a specular glow riding the filled arc.
        case prismShaderGlow
        /// P6 — STATIC native `MeshGradient` prism masked to the ring rim. No
        /// driver, no animation, no Metal — renders once. (Renders in the
        /// Simulator, unlike P4/P5.)
        case prismStatic
        /// P9 (W-B190) — the SHIPPING prism: a pure-SwiftUI `MeshGradient` spectral
        /// wash masked STRICTLY to the FILLED arc (`0…fraction`, the same trim as
        /// `HLScoreRing`) plus a subtle STEADY glow on that arc. NO Metal, NO
        /// `.layerEffect` — renders identically on every tile (hero + small) on
        /// device AND in the Simulator. Reduce-motion / Low-Power → the glow drops
        /// to its static still frame.
        case prismUniform
    }

    let style: InsightsTileStyle
    let surface: Surface
    /// The single signal cap dot the ring draws (the only colour on the grid), or
    /// `nil` for a pure-mono ring.
    let ringSignal: HLScoreRing.HLSignal?
    /// `true` when the surface is the warm gradient → the ring needs the white
    /// off-ink + the soft dark legibility shadow (mono surfaces keep default ink).
    let usesGradientInk: Bool
    /// The b182 optical/motion treatment over the ring (`.none` on A / C / F).
    let ringEffect: RingEffect

    init(style: InsightsTileStyle, signal _: HLScoreRing.HLSignal?) {
        self.style = style
        // P9 `prismUniform` is the sole shipped look (v0152 T1): plain mono
        // surface + the pure-SwiftUI arc-masked prism (uniform on hero AND small
        // tiles), no cap dot (the operator asked for "kein Punkt vorne im Kreis").
        surface = .mono
        usesGradientInk = false
        ringSignal = nil
        ringEffect = .prismUniform
    }

    /// The ring fill colour override — white off-ink on the gradient surface,
    /// `nil` (primitive default graphite, dark-mode-flipping) on mono / glass.
    var ringFill: Color? {
        usesGradientInk ? WellnessRingPalette.fill : nil
    }

    var ringTrack: Color? {
        usesGradientInk ? WellnessRingPalette.track : nil
    }

    var ringValueColor: Color? {
        usesGradientInk ? WellnessRingPalette.value : nil
    }

    var ringLabelColor: Color? {
        usesGradientInk ? WellnessRingPalette.label : nil
    }

    /// The under-ring metric label colour — calm off-white on the gradient,
    /// primary ink on the mono / glass surfaces.
    var labelColor: Color {
        usesGradientInk ? WellnessRingPalette.label : HLText.primary
    }

    /// `true` when the ring needs the soft-dark legibility shadow (only on the
    /// white-on-gradient surface).
    var ringShadowActive: Bool {
        usesGradientInk
    }
}
