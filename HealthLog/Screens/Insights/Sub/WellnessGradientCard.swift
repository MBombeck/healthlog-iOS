import SwiftUI

// MARK: - Convergent wellness-gradient card surface (v0.14.4 FW-WELL)

/// A card surface that paints a `WellnessGradient` Verlauf (saturated metric hue
/// at the OUTER corner → shared light end at the INNER grid-centre corner) under
/// the mono ring + label. When `gradient` is `nil` (non-wellness or insufficient
/// state) it falls back to the plain `HLCard` surface so semantics are unchanged.
///
/// **Contrast handling (v0.14.10 §1).** The ring + value + label are WHITE on the
/// gradient, which is now a TINTED-DARK field (hue→near-black base). White reads
/// crisply on the dark tile with no extra wash needed, so the old dark legibility
/// scrim is dropped and replaced with a faint WHITE radial lift centred on the
/// ring — it gives the lockup a subtle premium glow without lightening the tile.
/// The ring's own `WellnessRingShadow` keeps a soft-dark safeguard on the stroke.
///
/// **Living-light motion (v0.14.11 Task C).** The white radial lift now BREATHES
/// very subtly — opacity + radius — driven by `WellnessTileMotion`, phase-offset
/// per tile by `glowPhaseIndex` so the grid never pulses in unison. Under Reduce
/// Motion the breath is OFF (the static mid value renders, no `TimelineView`).
struct WellnessGradientCard<Content: View>: View {
    let gradient: WellnessGradient?
    /// v0.14.11 — the tile's grid index, used ONLY to phase-offset the "living
    /// light" glow breath so neighbours never pulse in unison. Defaults to 0
    /// (callers that don't thread an index get a single, valid phase).
    var glowPhaseIndex: Int = 0
    /// v0.14.11 Task B — an explicit tile gradient override (the CYCLE tile builds
    /// a dark-tinted gradient from its WARM phase tint, so it can't go through the
    /// metric-ID `WellnessGradient` enum). When set it paints the SAME tile chrome
    /// (glow + border + shadow) so the cycle tile is visually a sibling. Ignored
    /// when `gradient` is non-nil.
    var customGradient: LinearGradient?
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live Low-Power read — the breath drops to its static mid value when on,
    /// mirroring the canonical gate on the prism/cycle-glow drivers
    /// (`InsightsPrismShader.swift`, `InsightsRingEffects.swift`).
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        if let backdrop = gradient?.linearGradient ?? customGradient {
            content
                .padding(HLSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        backdrop
                        // v0.14.10 §1 — the tile is now a TINTED-DARK field, so the
                        // old dark legibility scrim is unnecessary (white already
                        // reads on dark). A faint WHITE radial lift centred on the
                        // ring/label lockup adds a subtle premium glow without
                        // lightening the tile, and fades to clear toward the edges.
                        // v0.14.11 — the glow now BREATHES very subtly (opacity +
                        // radius), phase-offset per tile, gated OFF under Reduce
                        // Motion (then the static mid value renders).
                        glow
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                        .strokeBorder(HLColor.wellnessTileBorder, lineWidth: 1)
                )
                .hlShadow(HLShadow.cardLight)
        } else {
            HLCard { content }
        }
    }

    /// The white radial lift under the ring lockup. Under Reduce Motion OR
    /// Low-Power it renders the fully STATIC mid (`breath == 0`) value — the
    /// `TimelineView` is `paused:` so it collapses to a single still frame, no
    /// per-frame redraw. Otherwise one cheap `TimelineView` capped to the
    /// canonical 20 fps driver interval (matching the prism / cycle-glow drivers,
    /// not full display refresh) drives a slow low-frequency sine breath of the
    /// glow opacity + radius, phase-offset by `glowPhaseIndex` so the tiles never
    /// pulse together.
    @ViewBuilder
    private var glow: some View {
        let paused = WellnessTileMotion.isPaused(reduceMotion: reduceMotion, lowPower: lowPower)
        TimelineView(.animation(minimumInterval: WellnessTileMotion.frameInterval, paused: paused)) { context in
            let b = paused
                ? 0
                : WellnessTileMotion.breath(
                    seconds: context.date.timeIntervalSinceReferenceDate,
                    index: glowPhaseIndex
                )
            radialGlow(
                opacityScale: WellnessTileMotion.opacityScale(breath: b),
                endRadius: WellnessTileMotion.endRadius(breath: b)
            )
        }
    }

    /// `opacityScale` modulates the base `HLColor.wellnessTileGlow` (white @0.06)
    /// around 1.0 — `Color.opacity()` multiplies, so at scale 1.0 the static base
    /// glow renders unchanged (mono-token-routed, no raw white literal).
    private func radialGlow(opacityScale: Double, endRadius: CGFloat) -> some View {
        RadialGradient(
            colors: [HLColor.wellnessTileGlow.opacity(opacityScale), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: endRadius
        )
    }
}
