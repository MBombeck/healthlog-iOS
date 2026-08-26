import SwiftUI

/// **S4b (marathon b182) — the shared leaf-tile SURFACE for the switchable
/// Insights score tiles.**
///
/// One helper all five ring cards wrap their lockup in, so the per-style surface
/// branch (mono `HLCard` / Liquid Glass / one shared neutral gradient) lives in
/// exactly ONE place. The content lockup (ring / number / label) is supplied by
/// the card; this view only decides the chrome. Removability post-selection is
/// mechanical: inline the winning branch and delete the rest.
///
/// - **mono** (A / B / D / E): the plain `HLCard` surface — identical chrome to
///   every other card in the app (kills the R5 cross-screen inconsistency).
/// - **glass** (C): a Liquid Glass surface via `hlGlassBackground` (iOS 26+),
///   gracefully degrading to the flat `HLSurface.secondary` fill on iOS 18–25 —
///   on older OS it reads like the mono surface (Concept A), which is the intended
///   graceful fallback. A faint inner highlight + soft drop shadow add depth.
/// - **restrainedGradient** (F): ONE shared very-subtle warm-neutral gradient on
///   every tile (drops the eight per-metric hues), reusing the existing glow +
///   border + shadow chrome from `WellnessGradientCard` so the grid reads as one
///   calm field with gentle depth instead of a rainbow.
struct InsightsTileSurface<Content: View>: View {
    let appearance: InsightsTileAppearance
    /// Grid index — phase-offsets the restrained-gradient "living light" breath so
    /// neighbouring tiles never pulse in unison (reused from `WellnessTileMotion`).
    var glowPhaseIndex: Int = 0
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live Low-Power read — the breath drops to its static mid value when on,
    /// mirroring the canonical gate on the prism/cycle-glow drivers
    /// (`InsightsPrismShader.swift`, `InsightsRingEffects.swift`).
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
    }

    var body: some View {
        switch appearance.surface {
        case .mono:
            HLCard { content }
        case .glass:
            glassSurface
        case .restrainedGradient:
            gradientSurface
        case .glassTile:
            glassTileSurface
        }
    }

    /// Concept P4 (b182) — native iOS-26 `glassEffect` on the tile SURFACE inside a
    /// `GlassEffectContainer` (HIG: glass on the surface, never on the data ring
    /// stroke). The ring stays a crisp gradient stroke on top. `.ultraThinMaterial`
    /// fallback on iOS 18–25. Does NOT render the lensing/specular in the
    /// Simulator — judge on a device.
    private var glassTileSurface: some View {
        HLGlassEffectContainer(spacing: HLSpace.md) {
            content
                .padding(HLSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(GlassTileSurfaceChrome(shape: cardShape))
        }
    }

    /// Concept C — Liquid Glass (iOS 26+) with a faint inner highlight + soft
    /// shadow for depth; flat `HLSurface.secondary` fallback on iOS 18–25.
    private var glassSurface: some View {
        content
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hlGlassBackground(in: cardShape, fallback: HLSurface.secondary)
            .clipShape(cardShape)
            .overlay(
                cardShape.strokeBorder(HLColor.wellnessTileBorder, lineWidth: 1)
            )
            .hlShadow(HLShadow.card)
    }

    /// Concept F — one shared neutral warm gradient on every tile, with the same
    /// breathing white radial lift + border + shadow as `WellnessGradientCard` so
    /// the depth reads as quiet life, not decoration.
    private var gradientSurface: some View {
        content
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Self.sharedNeutralGradient
                    glow
                }
            }
            .clipShape(cardShape)
            .overlay(
                cardShape.strokeBorder(HLColor.wellnessTileBorder, lineWidth: 1)
            )
            .hlShadow(HLShadow.cardLight)
    }

    /// The SINGLE shared neutral gradient for Concept F — a hair-lighter top
    /// corner blending to the shared near-black `wellnessGradientDark` base. One
    /// tone on every tile, so the grid reads as one calm field, not a rainbow.
    static var sharedNeutralGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(
                    color: HLColor.wellnessGradientDark.blended(with: .white, fraction: 0.06),
                    location: 0
                ),
                .init(color: HLColor.wellnessGradientDark, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The breathing white radial lift (reused from `WellnessGradientCard`).
    /// Static at the mid (`breath == 0`) value under Reduce Motion OR Low-Power;
    /// otherwise a slow sine breath phase-offset per tile. The `TimelineView` is
    /// capped to the canonical 20 fps driver interval (matching the prism /
    /// cycle-glow drivers) instead of running at full display refresh, and
    /// `paused:` collapses it to its still frame when gated.
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

    private func radialGlow(opacityScale: Double, endRadius: CGFloat) -> some View {
        RadialGradient(
            colors: [HLColor.wellnessTileGlow.opacity(opacityScale), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: endRadius
        )
    }
}

/// P4 (b182) — the native-glass tile surface chrome: `glassEffect` on iOS 26+,
/// `.ultraThinMaterial` fallback on iOS 18–25. Folded into one modifier so the
/// availability branch lives in exactly one place. The lensing/specular eyecatch
/// only renders on a physical device (not the Simulator).
private struct GlassTileSurfaceChrome: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        // 08-12 — the `#available` branch stays, because it decides which of
        // two *different* treatments the tile gets on each OS (glass, versus
        // material plus a border and a shadow the glass path does not want).
        // What changes is that neither branch reaches a raw primitive any more:
        // both route through the seams that read Reduce Transparency first, so
        // an iOS-26 device with the preference on lands on `HLSurface.secondary`
        // — the same fill the sibling `glassSurface` already falls back to —
        // instead of glass the user asked not to see.
        if #available(iOS 26.0, *) {
            content
                .hlGlassEffect(in: shape, interactive: true, fallback: HLSurface.secondary)
        } else {
            content
                .background(
                    HLMaterialBackground(.ultraThinMaterial, solidFallback: HLSurface.secondary)
                        .clipShape(shape)
                )
                .overlay(shape.strokeBorder(HLColor.wellnessTileBorder, lineWidth: 1))
                .hlShadow(HLShadow.card)
        }
    }
}

#Preview("Insights tile (P9 prismUniform)") {
    let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]
    ScrollView {
        LazyVGrid(columns: columns, spacing: HLSpace.md) {
            previewTile(style: .prismUniform, score: 84, signal: .ok, label: "Readiness", index: 0)
            previewTile(style: .prismUniform, score: 32, signal: .bad, label: "Stress", index: 1)
        }
        .padding(HLSpace.lg)
    }
    .background(HLSurface.primary)
}

@ViewBuilder
@MainActor
private func previewTile(
    style: InsightsTileStyle,
    score: Double,
    signal: HLScoreRing.HLSignal,
    label: String,
    index: Int
) -> some View {
    let appearance = style.appearance(signal: signal)
    InsightsTileSurface(appearance: appearance, glowPhaseIndex: index) {
        VStack(spacing: HLSpace.sm) {
            HLScoreRing(
                fraction: score / 100,
                value: "\(Int(score))",
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor
            )
            .frame(width: 96, height: 96)
            .insightsRingEffect(appearance.ringEffect, fraction: score / 100, isHero: index == 0)
            .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
            Text(label)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(appearance.labelColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.xs)
    }
}
