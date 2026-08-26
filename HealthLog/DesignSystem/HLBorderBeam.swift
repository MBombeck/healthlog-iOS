import SwiftUI

/// **Border-Beam — monochrome one-shot confirmation sweep.**
///
/// A luminous silver beam with a fading comet tail that travels ONCE around a
/// rounded-rectangle border, then fades out. Adapted from Magic UI's "Border
/// Beam" reference (operator brief, v0.14 BC) into our monochrome doctrine:
/// the gradient is white/silver only — **never** an accent tint — so the beam
/// reads as Liquid-Glass chrome light, not a coloured celebration.
///
/// Unlike the Magic UI default (an infinite 6s loop), this plays a SINGLE
/// 0→360° rotation (~0.9s) the moment a `trigger` value changes — the intake
/// "Genommen" confirmation beat — then auto-fades. It is purely decorative
/// chrome drawn in an overlay; it never affects layout or hit-testing.
///
/// **Reduce-motion:** the rotating sweep is skipped entirely. Instead a calm
/// static silver border briefly fades in and out, so the confirmation still
/// reads without any travelling motion (WCAG 2.3.3 / animation-from-interaction).
///
/// Drive it with the `.hlBorderBeam(trigger:cornerRadius:)` modifier; pass a
/// monotonically changing value (a tap counter or a `Bool`-derived `Int`).
struct HLBorderBeam: ViewModifier {
    /// Monotonic trigger — every change replays the one-shot sweep.
    let trigger: Int
    /// Corner radius of the host surface, so the beam hugs the same shape.
    let cornerRadius: CGFloat
    /// Stroke width of the travelling beam.
    var lineWidth: CGFloat = 2
    /// **v0.14.1 ITEM-B** — beam comet tint. Defaults to silver (`.white`) for
    /// the "Genommen" confirm; the "Überspringen" sweep passes
    /// `HLColor.skipBeam` (sanctioned dark orange) so a skip reads as a
    /// distinct signal while reusing the exact same one-shot sweep.
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0→1 sweep progress, mapped to a 0→360° rotation of the comet gradient.
    @State private var sweep: CGFloat = 0
    /// Beam opacity — rides up at the start of the sweep and fades to 0 at the
    /// end so the beam vanishes cleanly rather than snapping off.
    @State private var beamOpacity: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if reduceMotion {
                    // Calm static confirmation: a soft silver border that fades
                    // in and back out — no travelling light.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(0.7), lineWidth: lineWidth)
                        .opacity(beamOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    beam
                }
            }
            .onChange(of: trigger) { _, _ in
                play()
            }
    }

    private var beam: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        // Comet tail: transparent → faint → bright head → transparent.
                        .init(color: .clear, location: 0.0),
                        .init(color: tint.opacity(0.0), location: 0.55),
                        .init(color: tint.opacity(0.85), location: 0.92),
                        .init(color: tint, location: 0.97),
                        .init(color: .clear, location: 1.0)
                    ]),
                    center: .center,
                    angle: .degrees(Double(sweep) * 360)
                ),
                lineWidth: lineWidth
            )
            // Soft glow so the head reads as luminous, not a hard line.
            .shadow(color: tint.opacity(0.55 * beamOpacity), radius: 6)
            .blur(radius: 0.4)
            .opacity(beamOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func play() {
        if reduceMotion {
            // Brief silver-border fade-in/out, no rotation.
            beamOpacity = 0
            withAnimation(.easeOut(duration: 0.18)) { beamOpacity = 1 }
            withAnimation(.easeIn(duration: 0.45).delay(0.35)) { beamOpacity = 0 }
            return
        }
        sweep = 0
        beamOpacity = 0
        // Fade the beam in fast, then carry it once around and fade out at the
        // tail of the sweep (~1.8s total) so the comet exits cleanly. Operator
        // wanted a single, calmer lap — not the earlier ultra-fast ~0.9s.
        withAnimation(.easeOut(duration: 0.12)) { beamOpacity = 1 }
        withAnimation(.easeInOut(duration: 1.8)) { sweep = 1 }
        withAnimation(.easeIn(duration: 0.3).delay(1.5)) { beamOpacity = 0 }
    }
}

extension View {
    /// Plays a monochrome one-shot border-beam sweep around this view each time
    /// `trigger` changes. Decorative chrome only — never affects layout or hit
    /// testing; reduce-motion degrades to a calm static border pulse.
    func hlBorderBeam(
        trigger: Int,
        cornerRadius: CGFloat,
        lineWidth: CGFloat = 2,
        tint: Color = .white
    ) -> some View {
        modifier(HLBorderBeam(trigger: trigger, cornerRadius: cornerRadius, lineWidth: lineWidth, tint: tint))
    }
}

#if DEBUG
    #Preview("Border Beam") {
        struct Demo: View {
            @State private var trigger = 0
            var body: some View {
                VStack(spacing: 32) {
                    RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                        .fill(HLSurface.secondary)
                        .frame(height: 120)
                        .hlBorderBeam(trigger: trigger, cornerRadius: HLRadius.card)
                    Button("Confirm") { trigger += 1 }
                }
                .padding()
                .background(HLColor.background)
            }
        }
        return Demo()
    }
#endif
