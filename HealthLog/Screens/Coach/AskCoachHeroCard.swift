// FW1-C (M6) — the Hero card is the sanctioned AI-brand moment: white chrome
// on a near-black ink scrim in BOTH appearances. The raw white / black colour
// literals were tokenized into `HLColor.aiHeroInk` / `HLColor.aiHeroScrim`
// (DesignSystem/Tokens.swift), so the chromatic exception is now auditable in
// one place and this file no longer needs a file-level `forbidden_color`
// disable. See `docs/design-handbook-v1.md` §5 "Exceptions" for the rationale.
//
// Layout-wise this is the Y3 inline-scrolling Hero — the card sits
// inline in the Insights body, scrolls with content, and morphs into /
// out of the Gravatar-style coin through the matchedGeometry namespace.
//
import SwiftUI

/// Hero card for the "Frag den Coach"-surface on the Insights tab.
///
/// **b146 — monochrome graphite.** The card represents the AI-brand-
/// moment, but per the Theme-2.0 monochrome doctrine it does so with a
/// neutral graphite gradient + white chrome, not a saturated hue. The
/// gradient + white chrome + spotlight overlay carry the identity; the
/// Y3 inline-scrolling structure stays.
///
/// **Visual recipe:**
/// - 132pt tall canvas, diagonal neutral graphite `LinearGradient`
///   (`HLText.primary` → 70%, topLeading→bottomTrailing) — monochrome
///   doctrine (b146).
/// - White radial spotlight overlay at `.topTrailing` (subtle, 0.16 max)
///   — fakes a soft specular highlight without iOS-26-only APIs.
/// - 28pt `sparkles` SF Symbol, white `.hierarchical`, gated
///   `.symbolEffect(.pulse, options: .repeating)` (reduce-motion aware).
/// - 22pt white headline + 15pt white-78% subhead, German first.
/// - Trailing `.thinMaterial` capsule pill ("Stell deine Frage" +
///   chevron) — glass-on-graphite, mirrors Apple Fitness's gradient cards.
/// - Light haptic on tap (`.sensoryFeedback(.impact(weight: .light))`).
///
/// **Accessibility:** entire card is one tappable element with a
/// composed accessibility label + hint; the decorative sparkles +
/// spotlight are `.accessibilityHidden(true)`. The graphite gradient
/// base passes WCAG AA contrast against the white headline (dark
/// `HLText.primary` ramp, luminance well under white text at 22pt bold).
struct AskCoachHeroCard: View {
    let action: () -> Void
    /// **COACH-COIN (v0.5.5.7)** — optional dismiss-handler. When set,
    /// the card paints a small X-button top-right that invokes this
    /// closure on tap. Callers (`InsightsScreen`) wire this to a
    /// `SettingsStore.coachHeroDismissed = true` mutation so the next
    /// frame replaces the Hero with the collapsed coin.
    var onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tap-pulse counter feeds `.sensoryFeedback` so back-to-back taps
    /// still fire the haptic even before the sheet has finished
    /// presenting. Mirrors the `homePath`/`captureTapPulse` pattern in
    /// `AuthenticatedShell`.
    @State private var tapPulse: Int = 0
    @State private var dismissPulse: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                tapPulse &+= 1
                action()
            } label: {
                content
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: tapPulse)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Ask the coach"))
            .accessibilityHint(String(localized: "What would you like to know today?"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("InsightsScreen.askCoachHeroCard")

            if let onDismiss {
                dismissButton(action: onDismiss)
                    .padding(.top, HLSpace.sm)
                    .padding(.trailing, HLSpace.sm)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dismissPulse)
    }

    /// X-button affordance — `xmark.circle.fill` on a `.ultraThinMaterial`
    /// circular backplate so the glyph reads above the graphite
    /// gradient without re-tinting the underlying surface.
    ///
    /// **Tap-target:** the visible glyph stays at `HLIconSize.lg`
    /// (+ `padding(6)` ≈ 34pt visual), but the
    /// Button's hit area is expanded to the HIG-mandated 44pt via
    /// `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())`
    /// so the dismiss action is reachable on small thumbs.
    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button {
            dismissPulse &+= 1
            action()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.hlIcon(HLIconSize.lg))
                .symbolRenderingMode(.palette)
                .foregroundStyle(HLColor.aiHeroInk, HLColor.aiHeroInk.opacity(0.22))
                .padding(HLSpace.chip)
                // Expand the hit area to HIG-minimum 44pt without scaling
                // the 22pt glyph. `contentShape(Rectangle())` makes the
                // full expanded frame tappable.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Hide hero card"))
        .accessibilityHint(String(localized: "Hide the coach card; a coach button appears in the top right."))
        .accessibilityIdentifier("InsightsScreen.askCoachHeroCard.dismiss")
    }

    // MARK: - Visual stack

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // 1. Base — v0.14.3 B1: a COLOURFUL purple→amber gradient (operator
            // brief: the Coach tile must read as a real, vivid "hero", not a flat
            // black tile). This is the sanctioned chromatic exception to the
            // monochrome doctrine, tokenized as `HLColor.aiHeroGradient` (the
            // deep-violet → vivid-purple → warm-amber sweep). White chrome
            // (`HLColor.aiHeroInk`) stays legible across the whole sweep, and the
            // gradient is appearance-invariant so the AI moment reads identically
            // in light + dark. A dark scrim overlay (below) anchors text contrast.
            LinearGradient(
                gradient: HLColor.aiHeroGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Contrast guard — a soft dark scrim from the leading edge keeps the
            // white headline/subhead AA-legible over the bright amber end of the
            // sweep without muddying the hue.
            LinearGradient(
                colors: [HLColor.aiHeroScrim.opacity(0.32), Color.clear],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .accessibilityHidden(true)

            // 2. Soft radial spotlight — fakes the specular highlight a
            // real Liquid-Glass surface would emit, without forcing the
            // iOS-26-only path. Centered at the top-trailing corner so
            // it catches the chevron pill below.
            RadialGradient(
                colors: [HLColor.aiHeroInk.opacity(0.16), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )
            .blendMode(.plusLighter)
            .accessibilityHidden(true)

            // 3. Content lockup — pinned 20pt from each edge so the
            // gradient breathes around the lockup.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                sparklesGlyph
                Text(String(localized: "Ask the coach"))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(HLColor.aiHeroInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(String(localized: "Your data, explained. Ask anything about your trends, scores, or what to watch."))
                    .font(.hlSubhead)
                    .foregroundStyle(HLColor.aiHeroInk.opacity(0.82))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ctaPill
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.vertical, HLSpace.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 144)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        .overlay(
            // Hairline inner highlight pulled from the spotlight — keeps
            // the card edge from disappearing on dark backdrops.
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .strokeBorder(HLColor.aiHeroInk.opacity(0.18), lineWidth: 1)
        )
        .hlShadow(HLShadow.card)
        .contentShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    // MARK: - Sparkles glyph (motion-gated pulse)

    private var sparklesGlyph: some View {
        Image(systemName: "sparkles")
            .font(.hlIcon(HLIconSize.hero))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(HLColor.aiHeroInk)
            // Pulse is the only motion on the card. Reduce-motion users
            // see a static glyph (still legible, still hierarchical).
            .symbolEffect(
                .pulse,
                options: reduceMotion ? .nonRepeating : .repeating,
                isActive: !reduceMotion
            )
            .accessibilityHidden(true)
    }

    // MARK: - Glass CTA pill ("Stell deine Frage" + chevron)

    private var ctaPill: some View {
        HStack(spacing: HLSpace.xs) {
            Text(String(localized: "Ask your question"))
                .font(.hlFootnote.weight(.semibold))
                .foregroundStyle(HLColor.aiHeroInk)
            HLDisclosureChevron(tint: HLColor.aiHeroInk)
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.chip)
        // W3b B4 — the hero CTA pill is a floating control sitting on the
        // graphite gradient. iOS 26: interactive Liquid Glass capsule
        // (system handles the edge, so the manual white stroke is dropped per
        // the skill rule "no custom borders on glass"). iOS 18-25: the prior
        // `.thinMaterial` capsule + white hairline stroke for legibility on
        // the gradient. The whole hero card is the tappable button; this pill
        // is the visual affordance, so the glass still reads interactive.
        .modifier(AskCoachCTAPillBackground())
        .accessibilityHidden(true)
    }
}

/// W3b B4 — hero CTA pill background. iOS 26: interactive Liquid Glass capsule
/// (no manual stroke — system owns the edge). iOS 18-25: the prior
/// `.thinMaterial` capsule + white hairline stroke for legibility on the
/// graphite gradient.
///
/// **08-14:** both branches now go through 08-04's seams, so the preference is
/// read before the OS version on either path. The opaque answer is
/// `HLColor.aiHeroScrim` on both — the pill is the one place in the app that
/// floats over the vivid `aiHeroGradient`, and `aiHeroInk` is white, so the
/// legible non-translucent capsule is the hero's own appearance-invariant
/// near-black rather than a neutral surface token that would invert with the
/// colour scheme underneath a gradient that does not.
private struct AskCoachCTAPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.hlGlassEffect(
                in: Capsule(style: .continuous),
                interactive: true,
                fallback: HLColor.aiHeroScrim
            )
        } else {
            content
                .background(
                    HLMaterialBackground(.thinMaterial, solidFallback: HLColor.aiHeroScrim)
                        .clipShape(Capsule(style: .continuous))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(HLColor.aiHeroInk.opacity(0.32), lineWidth: 1)
                )
        }
    }
}

#Preview("AskCoachHeroCard") {
    VStack(spacing: HLSpace.lg) {
        AskCoachHeroCard {}
    }
    .padding(HLSpace.lg)
    .background(HLSurface.primary)
}
