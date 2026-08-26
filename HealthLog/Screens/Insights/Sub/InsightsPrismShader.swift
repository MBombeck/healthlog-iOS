import SwiftUI

/// **P5x (EXPERIMENTAL) — the real chromatic-rim prism via a Metal `.layerEffect`.**
///
/// The genuine prism the operator asked for: per pixel we measure the distance to
/// the ring stroke, build a thin `smoothstep` band (zero in the flat interior),
/// and sample the rasterised ring 3× with the R/G/B sample positions pushed apart
/// radially — white rim pixels split into faint green/yellow/blue/red exactly like
/// a lens fringe (see `TILESFX-research-shader.md` Concept 1). The MSL lives in
/// `InsightsRingPrism.metal` (own ~30-line `[[ stitchable ]]` shader, no vendored
/// dependency — learned from krispuckett/SwiftUIShaders + Inferno).
///
/// **W-B186 / W-B187 — strictly masked to the FILLED arc only.** The plain
/// `HLScoreRing` is the base; the chromatic-prism copy is OVERLAID and masked to the
/// progressed arc (`RingFilledArcMask`, the same 0…`fraction` / 12-o'clock /
/// clockwise trim `HLScoreRing` draws), so the spectral break-up rides ONLY the
/// filled portion and the unfilled remainder reads as the clean mono "open" ring.
/// The colour edge lands exactly on the ring head. **W-B187** folds the optional
/// P5b glow UNDER the SAME mask (the glow's bloom halo would otherwise spill past
/// the head into the empty quarter) and runs the prism + glow off ONE shared
/// `TimelineView` clock — on the large hero "Tagesform" ring the previous two
/// unsynchronised clocks beat against each other and read as a glow flicker.
///
/// **W-B186 — geometry fix.** The shader's `center`/`radius` are derived from the
/// content's OWN rendered size (measured via `onGeometryChange`, not a greedy
/// outer `GeometryReader` that expanded to the tile and pushed the ring to the
/// top-leading corner) so on the hero "Tagesform" tile the prism aligns to the
/// ring's real centre + radius instead of the tile's.
///
/// **Reserved for the HERO ring** (`InsightsRingEffectModifier(isHero:)`): a live
/// backdrop-sampling shader on every scrolling grid tile janks the list, so the
/// grid tiles + reduce-motion + Low-Power degrade to the jank-free P1 overlay.
/// `maxSampleOffset` is kept tiny (≈4 pt — the fringe offset, not a blur radius)
/// so the engine working set stays small.
///
/// **Does NOT render in the Simulator / `ImageRenderer`** — judge on a device.
struct PrismShaderRim: ViewModifier {
    /// The ring fill fraction 0…1 — masks the chromatic break-up to the filled arc.
    let fraction: Double
    /// P5b — when `true`, a specular glow rides ALONG the filled arc on top of the
    /// prism (`PrismGlowArc`). `false` for plain P5.
    var glow: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live Low-Power read — the glow drops to its static cheap path when on.
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The content's own rendered size, measured WITHOUT disturbing layout (an
    /// outer `GeometryReader` would expand to the tile and decentre the ring).
    @State private var contentSize: CGSize = .zero

    func body(content: Content) -> some View {
        let side = min(contentSize.width, contentSize.height)
        let stroke = HLRing.derivedStroke(forSide: side)
        // The ring centreline radius the Canvas draws at: (side - stroke)/2.
        let radius = Float((side - stroke) / 2)
        let thickness = Float(stroke)
        let cx = Float(contentSize.width / 2)
        let cy = Float(contentSize.height / 2)

        ZStack {
            // Base — the plain mono ring; shows through where the arc mask clips
            // the prism away (the unfilled remainder reads as the "open" ring).
            content

            // W-B187 — the chromatic prism AND the optional P5b glow share ONE
            // clock and ONE arc mask. Two separate `TimelineView`s used to drive
            // them on the hero (the prism's here + the glow's own `HLGlowDriver`),
            // beating against each other on the large ring → the flicker the
            // operator saw ONLY on Tagesform. Folding both onto a SINGLE
            // `TimelineView` makes the hero one steady redraw loop. Skipped until
            // the size has been measured (the mask needs a real frame).
            if side > 0 {
                let paused = reduceMotion || lowPower
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
                    let seconds = paused ? 0 : ctx.date.timeIntervalSinceReferenceDate
                    ZStack {
                        // The chromatic-prism copy of the ring.
                        content
                            .layerEffect(
                                ShaderLibrary.insightsRingPrism(
                                    .float2(cx, cy),
                                    .float(radius),
                                    .float(thickness),
                                    .float(2.0), // off — radial fringe push in pt
                                    .float(0.2), // chroma — per-channel spread
                                    .float(Float(seconds))
                                ),
                                maxSampleOffset: CGSize(width: 4, height: 4)
                            )

                        // P5b — the specular glow riding the filled arc, phase-
                        // locked to the SAME `seconds` clock (no second timeline),
                        // so it never beats against the prism. Steady (fixed-mean
                        // bloom) inside `PrismGlowArc`.
                        if glow {
                            PrismGlowArc(fraction: fraction, t: seconds)
                                .allowsHitTesting(false)
                        }
                    }
                }
                // W-B187 — STRICT arc mask over BOTH the prism and the glow, so the
                // colour (and the bloom halo, which would otherwise spill past the
                // arc head) is gone EXACTLY where the white ring hasn't reached. The
                // mask reproduces the white fill's geometry (centre / radius / round
                // cap), so nothing tints the unfilled remainder.
                .mask {
                    RingFilledArcMask(fraction: fraction)
                }
            }
        }
        // Measure the content's intrinsic size without changing the layout: the
        // ring stays the layout driver (centred 96/140 pt), we just read its frame.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newValue in
            contentSize = newValue
        }
    }
}
