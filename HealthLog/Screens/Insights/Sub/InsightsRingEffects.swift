import SwiftUI

/// **b182 (TILESFX wave) — the eyecatchy ring-effect layer for the dev-switchable
/// Insights score tiles.**
///
/// A SELECTION of genuinely different optical/motion treatments wired behind the
/// dev tile-style picker for INTERNAL on-device review — nothing ships yet. Each
/// effect is applied by exactly ONE shared modifier, `.insightsRingEffect(…)`, so
/// every ring card stays branch-free: the card builds its `HLScoreRing` and hands
/// the resolved ``InsightsTileAppearance/RingEffect`` + the fill fraction to the
/// modifier.
///
/// **Discipline (every effect):**
/// - The ring body stays monochrome, the centre number + the signal cap dot are
///   untouched — effects only DECORATE the rim / arc, never repaint the data.
/// - ≤20 fps continuous redraw (the cycle-ring `HLGlowDriver` cadence); additive
///   layers live OUTSIDE `.drawingGroup()` (it clamps `.plusLighter`/`.screen`).
/// - A defined `accessibilityReduceMotion` still-frame (the `t = 0` mean).
/// - A `ProcessInfo.isLowPowerModeEnabled` cheap path (drop the live driver /
///   the Metal shader → a static fringe), so the effect never drains the battery.
///
/// **Real-device caveat:** the P4 native glass surface and the P5x Metal shader
/// do NOT render fully in the Simulator / `ImageRenderer` — the operator judges
/// these two on a physical device.
struct InsightsRingEffectModifier: ViewModifier {
    let effect: InsightsTileAppearance.RingEffect
    /// The ring fill fraction 0…1 (drives the bloom intensity + the shader band).
    let fraction: Double
    /// `true` for the single HERO ring — the experimental Metal shader is reserved
    /// for the hero only; on the grid tiles P5x degrades to the jank-free P1 prism
    /// overlay (per the perf research: never a live backdrop-sampling shader on
    /// every scrolling tile).
    var isHero: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live Low-Power read — when on, every effect drops to its static cheap path.
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func body(content: Content) -> some View {
        switch effect {
        case .none:
            content
        case .prismOverlay:
            content.overlay {
                PrismRimOverlay(animated: !reduceMotion && !lowPower)
                    .allowsHitTesting(false)
                    // Purely decorative rim — the ring value/signal is announced by
                    // HLScoreRing; keep VoiceOver off the unlabeled prism shapes.
                    .accessibilityHidden(true)
            }
        case let .specularSweep(dimmed, tint):
            content.overlay {
                RingSpecularGlint(
                    fraction: fraction,
                    animated: !reduceMotion && !lowPower,
                    dimmed: dimmed,
                    tint: tint
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        case .scoreBloom:
            content.background {
                ScoreBloomHalo(fraction: fraction, animated: !reduceMotion && !lowPower)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        case .prismShader:
            // EXPERIMENTAL — the real Metal rim shader on the HERO ring only, the
            // chromatic break-up masked to the FILLED arc (0…fraction); the grid
            // tiles (and reduce-motion / Low-Power) fall back to the jank-free P1
            // overlay so the scroll never re-samples a backdrop shader per tile.
            if isHero, !reduceMotion, !lowPower {
                content.modifier(PrismShaderRim(fraction: fraction))
            } else {
                content.overlay {
                    PrismRimOverlay(animated: !reduceMotion && !lowPower)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        case .prismShaderGlow:
            // P5b — P5's masked chromatic rim PLUS a specular glow on the filled
            // arc, hero-only; the grid tiles + reduce-motion / Low-Power degrade to
            // the jank-free P1 overlay (the live backdrop-sampling shader never runs
            // per scrolling tile). The glow honours reduce-motion with a hard cut.
            if isHero, !reduceMotion, !lowPower {
                content.modifier(PrismShaderRim(fraction: fraction, glow: true))
            } else {
                content.overlay {
                    PrismRimOverlay(animated: !reduceMotion && !lowPower)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        case .prismStatic:
            // P6 — STATIC native MeshGradient prism masked to the ring rim. No
            // driver / no animation, so there is NO reduce-motion or Low-Power
            // branch to take: the single rendered frame IS the still frame. The
            // soft thickness shadow sits BEHIND the ring, the prism + edge
            // highlight ride ON the rim — the number + signal stay untouched.
            content
                .background {
                    PrismStaticShadow()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay {
                    PrismStaticRim()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        case .prismUniform:
            // P9 (W-B190) — the SHIPPING default. A pure-SwiftUI prism masked to
            // the FILLED arc (0…fraction) PLUS a subtle steady glow on that arc.
            // Identical on EVERY tile (no `isHero` branch, no Metal), so it renders
            // on-device AND in the Simulator. The glow honours reduce-motion /
            // Low-Power (passes the static t = 0 frame inside the view).
            content.overlay {
                PrismUniformRim(fraction: fraction, animated: !reduceMotion && !lowPower)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Apply the b182 dev ring effect over an `HLScoreRing`. `isHero` reserves the
    /// experimental Metal shader for the single hero ring (grid tiles degrade to
    /// the jank-free prism overlay).
    func insightsRingEffect(
        _ effect: InsightsTileAppearance.RingEffect,
        fraction: Double,
        isHero: Bool = false
    ) -> some View {
        modifier(InsightsRingEffectModifier(effect: effect, fraction: fraction, isHero: isHero))
    }
}

// MARK: - Filled-arc mask (the canonical 0…fraction trim, shared by P5 / P5b)

/// **W-B186 — the SHARED filled-arc mask matching `HLScoreRing`'s fill arc EXACTLY.**
///
/// `HLScoreRing` draws its fill as a Canvas arc from 12 o'clock, clockwise, over
/// `0…fraction`, at the centreline radius `(side − stroke)/2`, stroke width
/// `HLRing.derivedStroke(forSide:)`, round cap. This view reproduces that arc as a
/// `Circle().trim(from: 0, to: fraction).stroke(…).rotationEffect(-90°)` — the same
/// idiom `HLSpecularSweep` uses — so when it is handed to `.mask { … }` the colour
/// field is clipped to precisely the progressed portion of the ring, with the colour
/// edge landing on the ring head. The circle is inset by `stroke/2` so its stroked
/// band straddles the SAME centreline the Canvas ring draws (Canvas outer edge sits
/// at `side/2`, so a plain `Circle().stroke` would overshoot by `stroke/2`).
///
/// `trim(to: 0)` produces an empty path → a 0-score ring shows NO prism at all
/// (the whole rim reads as the plain mono "open" ring), which is the intended
/// "nothing filled yet, nothing shimmers" end of the scale.
struct RingFilledArcMask: View {
    /// The ring fill fraction 0…1 (the same value fed to `HLScoreRing.fraction`).
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            let f = max(0, min(1, fraction))
            Circle()
                // Inset by stroke/2 so the stroked band rides the Canvas ring's
                // centreline radius (side − stroke)/2 — not stroke/2 proud of it.
                .inset(by: stroke / 2)
                .trim(from: 0, to: max(0.0001, f))
                .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                // 12 o'clock start, clockwise — identical to HLScoreRing's arc.
                .rotationEffect(.degrees(-90))
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A 0-fraction ring masks the prism away entirely (no shimmer at 0).
                .opacity(f <= 0 ? 0 : 1)
        }
    }
}

// MARK: - P5b · Prisma + Glanz — specular glow riding the filled arc

/// **P5b (W-B186) — P5's chromatic prism PLUS a specular glow on the filled arc.**
///
/// The operator wanted a glow variant alongside P5: the genuine Metal chromatic
/// rim (reserved for the hero ring) AND extra shine riding ALONG the progressed
/// arc, so the ring reads as lit where it has already reached. The glow reuses the
/// existing specular/bloom vocabulary — `HLSpecularSweep` (the metallic glide
/// masked to `0…fraction`) layered with a faint `HLBloomHalo` at the arc head — so
/// it is the same light-language as P2/P3, confined to the filled arc only.
///
/// **W-B187 — STEADY glow, strictly confined to the filled arc.** The operator
/// liked the glow but it FLICKERED on the hero "Tagesform" ring (and only there):
/// the hero ran the live Metal prism clock AND a SECOND, unsynchronised glow clock
/// (this view's own `HLGlowDriver`), so the two redraw loops beat against each
/// other on the large ring; the bloom's breathing opacity made the beating read as
/// a flicker. Two W-B187 changes kill it:
///
/// 1. **One clock.** This view no longer owns a `TimelineView` — the caller
///    (`PrismShaderRim`) passes the SHARED prism clock value `t`, so the glow is
///    phase-locked to the prism and there is exactly one redraw loop on the hero.
/// 2. **Steady bloom.** The arc-head bloom now rides a FIXED mean breath (0.5)
///    instead of `HLCycleRingGlowMath.breath(t)`, so its opacity/radius no longer
///    oscillate — the glow is PRESENT and calm, never pulsing. The specular sweep
///    keeps its gentle metallic glide on the shared clock (a single, smooth
///    rotation, no beating partner) so the arc still reads as "lit".
///
/// The whole glow is masked to `0…fraction` by the CALLER (the same
/// `RingFilledArcMask` the prism uses), so the bloom halo can never spill past the
/// arc head into the unfilled remainder. Reduce-motion / Low-Power → the caller
/// passes the static `t = 0` frame. Like P5, the chromatic rim does NOT render in
/// the Simulator — judge on a device.
struct PrismGlowArc: View {
    /// The ring fill fraction 0…1 (drives the glow arc + bloom-head anchor).
    let fraction: Double
    /// The SHARED prism clock (seconds), passed in by `PrismShaderRim` so the glow
    /// is phase-locked to the prism — no second `TimelineView`, no beating. Under
    /// reduce-motion / Low-Power the caller passes `0` (the static still frame).
    let t: Double

    @Environment(\.colorScheme) private var scheme

    /// The bloom's fixed mean breath — the visual centre of the old oscillation, so
    /// the glow sits at a calm steady level instead of pulsing (the flicker source).
    ///
    /// **W-B192 — lifted from 0.5 → 0.62.** The operator preferred the visibly
    /// brighter "Glanz" of P5b. Nudging the steady breath up makes the arc-head
    /// bloom read with more presence (a stronger, edle shine) while staying STEADY
    /// — it is a fixed level, not an oscillation, so there is still no pulse / no
    /// flicker. The whole glow remains confined to the filled arc by the caller.
    private static let steadyBreath: Double = 0.62

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            let ringRadius = (side - stroke) / 2
            let f = max(0.0001, min(1, fraction))
            // Anchor the bloom at the fill-arc head (12 o'clock + clockwise by f).
            let unit = ScoreBloomHalo.headUnitVector(fraction: f)
            ZStack {
                // Metallic glide masked to the filled arc only (0 → fraction).
                HLSpecularSweep(
                    arc: (start: 0, end: f),
                    stroke: stroke,
                    t: t,
                    scheme: scheme
                )
                // A STEADY bloom at the arc head — fixed mean breath so it never
                // pulses; W-B192 raised it so the progressed rim reads as edel "lit"
                // (the P5b-glow feel the operator liked), not just a faint touch. A
                // slightly larger base radius spreads the shine along the arc head
                // rather than a tight point.
                HLBloomHalo(
                    unit: unit,
                    markerRadius: ringRadius,
                    baseRadius: side * 0.24,
                    tint: .white,
                    breath: Self.steadyBreath,
                    scheme: scheme,
                    dimmed: false
                )
                .opacity(0.78)
            }
            .frame(width: side, height: side)
        }
    }
}

// MARK: - P1 · Prism-Rand (Overlay) — the jank-free prism

/// **P1 — `AngularGradient` spectrum stroked on the ring rim.**
///
/// The shader-research "cheap approximation": a full-spectrum `AngularGradient`
/// stroked as a thin rim, composited `.plusLighter` at ~0.35 so white-ish rim
/// pixels pick up faint green/yellow/blue/red while dark areas stay dark — a glass
/// edge fringe with ZERO Metal and no backdrop sampling, so it is safe on every
/// tile while scrolling. Animated by a slow `hueRotation` cycle on the shared
/// ≤20 fps clock; the static `t = 0` frame is the reduce-motion / Low-Power still.
struct PrismRimOverlay: View {
    let animated: Bool

    @Environment(\.colorScheme) private var scheme

    /// The spectrum, wrapping red→red so the angular sweep is seamless.
    private let spectrum: [Color] = [.red, .yellow, .green, .cyan, .blue, .purple, .red]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Match the score ring's derived rim so the prism sits ON the stroke.
            let stroke = HLRing.derivedStroke(forSide: side)
            HLGlowDriver(active: animated) { t in
                rim(side: side, stroke: stroke, hue: Self.hueDegrees(t))
            }
        }
    }

    /// Hue offset in degrees — a slow 12 s loop (ambient, not a transition).
    static func hueDegrees(_ t: Double) -> Double {
        (t / 12.0).truncatingRemainder(dividingBy: 1.0) * 360.0
    }

    private func rim(side: CGFloat, stroke: CGFloat, hue: Double) -> some View {
        Circle()
            .strokeBorder(
                AngularGradient(colors: spectrum, center: .center),
                lineWidth: stroke
            )
            .frame(width: side, height: side)
            // Confine the bright spectrum to a thin rim band over the stroke.
            .mask {
                Circle()
                    .strokeBorder(.white, lineWidth: stroke * 0.85)
                    .frame(width: side, height: side)
            }
            .hueRotation(.degrees(hue))
            .blur(radius: stroke * 0.12)
            .opacity(0.35)
            .blendMode(scheme == .dark ? .plusLighter : .screen)
    }
}

// MARK: - P2 · Glanz-Schimmer (specular sweep) — reuse HLSpecularSweep language

/// **P2 / P7 / P8 — a one-shot bright glint glides the fill arc when the value lands.**
///
/// Reuses the cycle-ring `HLSpecularSweep` vocabulary (thin white `AngularGradient`
/// band masked to an arc, additive blend) but as a SCORE-tile specular: it sweeps
/// the FILLED portion (0…`fraction`) once on the shared clock — "instrument
/// settling", the strongest single pick in the motion research. Reduce-motion /
/// Low-Power → a faint fixed highlight at the arc head (the `t = 0` still).
///
/// The shared `HLSpecularSweep` is NOT edited (the cycle ring's brightness must
/// stay as-is). Both the operator-requested ~12 % dim and the P8 signal tint are
/// applied TILE-LOCALLY here, wrapped around the unmodified sweep:
/// - `dimmed` → `.opacity(Self.dimFactor)` (0.88 ≈ −12 %). P2/P7/P8 all dim.
/// - `tint` (P8 only) → `.colorMultiply` by a mostly-white colour blended a low
///   `Self.tintBlend` toward the signal hue, so the white sheen reads as a faint
///   green/amber/red glint, not a coloured ring. `nil` keeps it mono (P2/P7).
struct RingSpecularGlint: View {
    let fraction: Double
    let animated: Bool
    /// ~12 % tile-local brightness cut the operator asked for (P2/P7/P8).
    var dimmed: Bool = false
    /// The metric's signal hue to bias the sheen toward (P8). `nil` → mono (P2/P7).
    var tint: HLScoreRing.HLSignal?

    @Environment(\.colorScheme) private var scheme

    /// −12 % ≈ ×0.88, applied tile-locally on top of the shared sweep.
    static let dimFactor: Double = 0.88
    /// How far the white sheen is pulled toward the signal hue — restrained so it
    /// stays a tinted glint, not a neon band.
    static let tintBlend: Double = 0.35

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            HLGlowDriver(active: animated) { t in
                // Sweep masked to the filled arc only (0 → fraction), top-anchored.
                HLSpecularSweep(
                    arc: (start: 0, end: max(0.001, min(1, fraction))),
                    stroke: stroke,
                    t: t,
                    scheme: scheme
                )
                .frame(width: side, height: side)
                // P8 — bias the white additive sheen toward the signal hue. A
                // mostly-white multiplier keeps the highlight bright while the hue
                // rides in faintly, so it reads as "a green/amber/red sheen".
                .colorMultiply(tintMultiplier)
                // Tile-local ~12 % dim (does NOT touch the shared HLSpecularSweep).
                .opacity(dimmed ? Self.dimFactor : 1)
            }
        }
    }

    /// `.white` (a no-op multiplier → mono P2/P7) or white blended a low fraction
    /// toward the signal hue (P8). Multiplying the additive white sweep by this
    /// shifts the sheen toward the hue without darkening it into a band.
    private var tintMultiplier: Color {
        let base = Color(white: 1)
        guard let tint else { return base }
        return base.blended(with: tint.color, fraction: Self.tintBlend)
    }
}

// MARK: - P3 · Score-Leuchten (bloom) — reuse HLBloomHalo, intensity ∝ score

/// **P3 — a soft halo behind the arc head, intensity mapped to the score.**
///
/// Reuses the cycle-ring `HLBloomHalo` verbatim, anchored at the fill-arc head
/// (top-clockwise) and SCALED by the score so a 90 glows confidently and a 35
/// barely glows — the glow *means* "high readiness", which is what keeps it from
/// being gratuitous (motion research §C). The breath rides on top via the shared
/// ≤20 fps clock; reduce-motion / Low-Power → the static mean-intensity halo.
struct ScoreBloomHalo: View {
    let fraction: Double
    let animated: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var diffNoColor

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            let ringRadius = (side - stroke) / 2
            // Anchor the bloom at the fill-arc head: 12 o'clock + clockwise by the
            // fill fraction, on the ring radius.
            let unit = Self.headUnitVector(fraction: fraction)
            HLGlowDriver(active: animated) { t in
                // breath in 0…1; t = 0 → 0.5 (the mean), which is the still frame.
                let breath = HLCycleRingGlowMath.breath(t)
                // Score-reactive base: a 35 sits near the floor, a 90 near the top.
                let scoreBreath = Self.scoreScaledBreath(fraction: fraction, breath: breath)
                HLBloomHalo(
                    unit: unit,
                    markerRadius: ringRadius,
                    baseRadius: side * 0.32,
                    tint: .white,
                    breath: scoreBreath,
                    scheme: scheme,
                    dimmed: diffNoColor
                )
                .frame(width: side, height: side)
            }
        }
    }

    /// Unit vector to the fill-arc head (12 o'clock start, clockwise sweep).
    static func headUnitVector(fraction: Double) -> (dx: Double, dy: Double) {
        let f = max(0, min(1, fraction))
        let rad = (-90.0 + 360.0 * f) * .pi / 180.0
        return (cos(rad), sin(rad))
    }

    /// Fold the score into the bloom's 0…1 breath input so a low score never
    /// glows much and a high score glows confidently — while the live breath
    /// still modulates around that score-set level.
    static func scoreScaledBreath(fraction: Double, breath: Double) -> Double {
        let f = max(0, min(1, fraction))
        // Score sets the floor (0.15 at 0, 0.85 at 100); breath adds ±~0.15.
        let floor = HLCycleRingGlowMath.lerp(0.15, 0.85, f)
        let wobble = (breath - 0.5) * 0.3
        return max(0, min(1, floor + wobble))
    }
}

// MARK: - P6 · Prisma (statisch) — STATIC native MeshGradient, no driver

/// **P6 — a STATIC `MeshGradient` (iOS 18+) prism masked to the ring rim.**
///
/// A clear (NOT milky/frosted) spectral layer: a `MeshGradient` of mostly clear
/// stops with a restrained cyan / mint / pale-yellow / faint-violet wash biased
/// DIRECTIONALLY toward ONE edge (lower-trailing) so the colour "flashes" at one
/// side like real clear-glass refraction, never an even rainbow. Overall opacity
/// is kept low (~8–18 %) so the ring + background read through. The whole layer is
/// MASKED to the ring rim (the annulus stroke band over `HLScoreRing`'s derived
/// stroke), so it tints the rim — never the flat interior, never the number, never
/// the signal dot. A fine white light edge highlight rides the rim crest.
///
/// **Fully static:** rendered ONCE — no `TimelineView`, no `HLGlowDriver`, no
/// Metal shader. There is therefore NO reduce-motion / Low-Power branch to take
/// (the single frame already IS the still frame), and — unlike the P4 glass
/// surface / the P5x Metal shader — it renders in the Simulator / `ImageRenderer`.
struct PrismStaticRim: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Match the score ring's derived rim so the prism sits ON the stroke.
            let stroke = HLRing.derivedStroke(forSide: side)
            ZStack {
                Self.prismMesh
                    // Confine the spectral wash to a thin band over the stroke.
                    .mask {
                        Circle()
                            .strokeBorder(.white, lineWidth: stroke * 0.9)
                            .frame(width: side, height: side)
                    }
                    .blur(radius: stroke * 0.10)
                    // Clear-glass feel: low overall opacity so ring + bg read through.
                    .opacity(scheme == .dark ? 0.16 : 0.13)
                    .blendMode(scheme == .dark ? .plusLighter : .screen)

                // A fine white light edge highlight on the rim crest.
                Circle()
                    .strokeBorder(.white, lineWidth: max(0.5, stroke * 0.10))
                    .frame(width: side, height: side)
                    .blur(radius: 0.4)
                    .opacity(scheme == .dark ? 0.45 : 0.30)
                    .blendMode(.plusLighter)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A 3×3 `MeshGradient` of mostly clear stops with a restrained spectral wash
    /// biased toward the LOWER / LOWER-TRAILING edge (the refraction "flash"). The
    /// colours are pale + low-alpha so the masked, low-opacity result stays clear,
    /// not milky.
    static let prismMesh = MeshGradient(
        width: 3,
        height: 3,
        points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.5, 0.5], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1]
        ],
        colors: [
            // Top row — almost clear (refraction barely touches the top edge).
            .clear, .white.opacity(0.04), .clear,
            // Middle row — a faint violet hint trailing-side, clear core.
            .clear, .clear, Color(red: 0.62, green: 0.55, blue: 0.92).opacity(0.16),
            // Bottom row — the spectral flash: mint → pale-yellow → cyan, biased
            // toward the lower-trailing corner.
            Color(red: 0.55, green: 0.95, blue: 0.80).opacity(0.18),
            Color(red: 0.98, green: 0.96, blue: 0.70).opacity(0.20),
            Color(red: 0.50, green: 0.90, blue: 0.98).opacity(0.28)
        ]
    )
}

/// The optional very soft drop shadow under the ring, giving the static prism a
/// hint of glass thickness. A clear, single-touch dark halo behind the rim — kept
/// faint so it never reads as a heavy card shadow.
struct PrismStaticShadow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            Circle()
                .strokeBorder(.black, lineWidth: stroke)
                .frame(width: side, height: side)
                .blur(radius: stroke * 0.6)
                .opacity(scheme == .dark ? 0.0 : 0.10)
                .offset(y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - P9 · Prisma (uniform) — the SHIPPING pure-SwiftUI arc-masked prism

/// **P9 (W-B190; W-RINGCOLOR colour fix) — the SHIPPING score-tile prism: pure
/// SwiftUI, arc-masked, uniform, with VISIBLE saturated colour.**
///
/// Renders identically on EVERY tile (hero + grid) on device AND in the Simulator —
/// NO Metal, NO `.layerEffect`. **W-RINGCOLOR core fix:** the prior P9 reused
/// `PrismStaticRim.prismMesh` (clear-glass, alpha 0.15–0.18) composited `.screen` /
/// `.plusLighter`, which washed to near-white — the operator saw a WHITE arc + glow,
/// i.e. it looked like effect A (no colour). His steer: "Wie P5b nur NICHT das Bunte
/// wo das Weisse nicht ist" — keep P5b's KRÄFTIGE full-spectrum colour
/// (`PrismRimOverlay`'s `AngularGradient`), bounded to the FILLED arc; the empty
/// remainder stays the plain mono track. So this view now paints:
///
/// - **Saturated prism arc** — the full red→yellow→green→cyan→blue→purple→red
///   `AngularGradient` stroked on the rim band at HIGH opacity with the DEFAULT
///   (source-over) blend, so the hues read as colour instead of bleaching out under
///   `.screen`. Masked STRICTLY to `0…fraction` via ``RingFilledArcMask`` (the same
///   trim `HLScoreRing` draws) → ZERO colour past the fill head. A slow hue-rotation
///   on the shared ≤20 fps clock keeps it alive; `t = 0` is the reduce-motion /
///   Low-Power still (the COLOUR is static, only the breath rests).
/// - **Even white sheen + glide** (W-RINGGLOSS) — a soft, BRIGHT white sheen rides
///   the whole filled arc (the operator's "noch weißer/heller") plus a gentle
///   ``HLSpecularSweep`` glint that sweeps the arc. The earlier point-anchored
///   arc-head bloom was dropped — on device it read as a bright "Ecke" at the fill
///   head; the even sheen lights the arc uniformly with no corner.
///
/// No cap dot is drawn here — the tile builds `HLScoreRing` with `signal: nil`.
struct PrismUniformRim: View {
    /// The ring fill fraction 0…1 — the prism + glow are masked to `0…fraction`.
    let fraction: Double
    /// `false` under reduce-motion / Low-Power → the glow uses its static frame and
    /// the spectrum hue-rotation rests (the colour itself stays present).
    let animated: Bool

    @Environment(\.colorScheme) private var scheme

    /// The full-spectrum prism, wrapping red→red so the angular sweep is seamless —
    /// the SAME saturated spectrum `PrismRimOverlay` (P5b's colour) uses.
    private static let spectrum: [Color] = [.red, .yellow, .green, .cyan, .blue, .purple, .red]

    /// **W-RINGGLASS-2 (operator: "viel zu bunt — viel, viel weißer").** The ring
    /// must read as a WHITE circle with the colours only FAINTLY in the background,
    /// not a coloured ring. So the colour is a low-opacity, un-boosted, diffuse
    /// ADDITIVE wash sitting UNDER a dominant white band — a faint cool tint behind
    /// the white, never a paint on the rim. (The b195 vivid+frost pass over-coloured
    /// it; this reverses that hard toward white.)
    private static let colorOpacity: Double = 0.22
    /// The dominant white band opacity — this is what the operator sees: a bright
    /// white ring. Pushed high so white clearly wins and the colour underneath is
    /// only a faint background presence.
    private static let whiteBandOpacity: Double = 0.82

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = HLRing.derivedStroke(forSide: side)
            ZStack {
                // The SUBTLE spectrum shimmer (P5b's `PrismRimOverlay` treatment,
                // verbatim: 0.35 opacity, soft blur, `.plusLighter`/`.screen` so it
                // sits BEHIND the white glow as a gentle prism), MASKED to the filled
                // arc only — the empty remainder stays the plain mono ring. This is
                // exactly what the operator asked for: P5b, just not shown where the
                // white ring isn't.
                HLGlowDriver(active: animated) { t in
                    ZStack {
                        // (1) FAINT cool colour in the BACKGROUND — a low-opacity,
                        // un-boosted, heavily-diffused additive wash that sits UNDER
                        // the white band as a soft tint, never a painted rim. A slow
                        // hue drift keeps it alive. This is the "coole Farben im
                        // Hintergrund" — present but clearly secondary to the white.
                        Circle()
                            .strokeBorder(
                                AngularGradient(colors: Self.spectrum, center: .center),
                                lineWidth: stroke
                            )
                            .frame(width: side, height: side)
                            .mask {
                                Circle()
                                    .strokeBorder(.white, lineWidth: stroke * 0.95)
                                    .frame(width: side, height: side)
                            }
                            .hueRotation(.degrees(PrismRimOverlay.hueDegrees(t)))
                            // Diffuse the colour wide so it reads as a background glow,
                            // not a rim; no saturation boost — it stays a quiet tint.
                            .blur(radius: stroke * 0.45)
                            .opacity(Self.colorOpacity)
                            .blendMode(scheme == .dark ? .plusLighter : .screen)

                        // (2) The DOMINANT WHITE band — a bright, soft white stroke
                        // riding the whole filled arc. This is the operator's "weißer
                        // Kreis": white clearly wins, the colour above is only a faint
                        // background presence beneath it.
                        Circle()
                            .strokeBorder(.white, lineWidth: stroke * 0.7)
                            .frame(width: side, height: side)
                            .blur(radius: stroke * 0.28)
                            .opacity(scheme == .dark ? Self.whiteBandOpacity : Self.whiteBandOpacity - 0.06)
                            .blendMode(.plusLighter)

                        // (3) A bright crisp white crest filament for the glass edge.
                        Circle()
                            .strokeBorder(.white, lineWidth: max(0.5, stroke * 0.12))
                            .frame(width: side, height: side)
                            .blur(radius: 0.5)
                            .opacity(scheme == .dark ? 0.6 : 0.5)
                            .blendMode(.plusLighter)
                    }
                    .frame(width: side, height: side)
                }
                .mask {
                    RingFilledArcMask(fraction: fraction)
                }

                // A gentle specular glide riding the WHOLE filled arc — the edle
                // "Glanz", kept EVEN (it sweeps along the arc, never resting as a
                // fixed bright point). **W-RINGGLOSS:** the point-anchored arc-head
                // bloom (`PrismGlowArc`'s `HLBloomHalo`) was dropped — on a real
                // device its radial blob read as a bright "Ecke" at the fill head,
                // which the operator flagged as the lighting looking wrong. The even
                // sheen above plus this gliding specular carry the lit feel with no
                // corner. `t = 0` is the reduce-motion / Low-Power still frame.
                let f = max(0.0001, min(1, fraction))
                if animated {
                    HLGlowDriver(active: true) { t in
                        HLSpecularSweep(arc: (start: 0, end: f), stroke: stroke, t: t, scheme: scheme)
                            .frame(width: side, height: side)
                    }
                    .opacity(0.55)
                } else {
                    HLSpecularSweep(arc: (start: 0, end: f), stroke: stroke, t: 0, scheme: scheme)
                        .frame(width: side, height: side)
                        .opacity(0.55)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Previews

/// Side-by-side of the b182 ring effects over a plain `HLScoreRing`. NOTE: the P4
/// native glass surface + the P5x Metal shader do NOT render fully in
/// `ImageRenderer` / the Simulator — judge those on a physical device.
private struct RingEffectPreviewCase: Identifiable {
    let id = UUID()
    let name: String
    let effect: InsightsTileAppearance.RingEffect
    let fraction: Double
}

#Preview("Ring effects (b182)") {
    let cases: [RingEffectPreviewCase] = [
        .init(name: "None (A)", effect: .none, fraction: 0.84),
        .init(name: "P1 Prism overlay", effect: .prismOverlay, fraction: 0.84),
        .init(name: "P2 Specular sweep", effect: .specularSweep(dimmed: true, tint: nil), fraction: 0.62),
        .init(name: "P7 Glint (no dot)", effect: .specularSweep(dimmed: true, tint: nil), fraction: 0.62),
        .init(name: "P8 Tinted glint", effect: .specularSweep(dimmed: true, tint: .ok), fraction: 0.62),
        .init(name: "P3 Score bloom · 90", effect: .scoreBloom, fraction: 0.90),
        .init(name: "P3 Score bloom · 35", effect: .scoreBloom, fraction: 0.35),
        .init(name: "P5 Prism shader", effect: .prismShader, fraction: 0.84),
        .init(name: "P5b Prism + glow", effect: .prismShaderGlow, fraction: 0.62),
        .init(name: "P6 Prism static", effect: .prismStatic, fraction: 0.84),
        .init(name: "P9 Prism uniform · 84", effect: .prismUniform, fraction: 0.84),
        .init(name: "P9 Prism uniform · 35", effect: .prismUniform, fraction: 0.35)
    ]
    return ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.xl) {
            ForEach(cases) { item in
                VStack(spacing: HLSpace.sm) {
                    HLScoreRing(fraction: item.fraction, value: "\(Int(item.fraction * 100))", signal: .ok)
                        .frame(width: 120, height: 120)
                        .insightsRingEffect(item.effect, fraction: item.fraction, isHero: true)
                    Text(item.name)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .padding(HLSpace.xl)
    }
    .background(HLSurface.primary)
}
