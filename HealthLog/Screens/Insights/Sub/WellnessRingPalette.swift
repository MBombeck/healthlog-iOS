import SwiftUI

// v0141 — extracted verbatim from `InsightsScoreCardsBlock.swift` to keep that
// file under the 600-line file-length lint budget after the per-card
// hide/show additions landed (project file-length discipline: split into
// thematic section files rather than let one file grow). Pure move — the
// palette + shadow modifier are unchanged.

/// **v0.14.1 (3rd contrast iter) — the WHITE wellness-ring palette for the
/// SATURATED convergent score tiles.**
///
/// The "Deine Gesundheitswerte" tiles are saturated per-metric gradients
/// (Tagesform green / Schlaf blue / Belastung purple / Erholung terracotta /
/// Stress rose). A prior pass tuned the ring fill + value + label to dark
/// graphite for an ASSUMED beige tile; on the real saturated hues dark read
/// heavy/out-of-place, so this flips them to WHITE — operator-confirmed as the
/// premium read on every hue. The track is white at low opacity so the recessed
/// channel reads on the gradient without competing with the fill. Hoisted
/// `nonisolated` so the palette is unit-testable without a SwiftUI host. The
/// legibility safeguard (a soft dark text shadow on the centre value/label,
/// applied at the call site) keeps white readable where the gradient's light
/// corner washes out (terracotta / rose).
enum WellnessRingPalette {
    /// The ring FILL arc on the coloured tiles — OFF-white. v0.14.1 polish: pure
    /// white on the (now dark) tiles read too bold/plakativ, so it's softened to
    /// ~0.90 so it blends into the dark field while staying crisply legible.
    nonisolated static let fillOpacity: Double = 0.90
    nonisolated static let fill: Color = .white.opacity(fillOpacity)
    /// The centre value ("92") — off-white at the same calm 0.90 (was pure white).
    nonisolated static let value: Color = .white.opacity(fillOpacity)
    /// The centre label ("Tagesform") — white at a LOWER opacity for hierarchy.
    /// v0.14.1 polish: dropped 0.85→0.70 so the metric label reads calmer (it was
    /// "extrem hart"); paired with a lighter font weight at the call site.
    nonisolated static let labelOpacity: Double = 0.70
    nonisolated static let label: Color = .white.opacity(labelOpacity)
    /// The unfilled track channel — white at low opacity so it reads on the
    /// gradient without competing with the bright fill.
    nonisolated static let trackOpacity: Double = 0.25
    nonisolated static let track: Color = .white.opacity(trackOpacity)
    /// Soft dark text shadow so white never disappears on the lightest gradient
    /// corner. v0.14.9 §4 — the −45% gradient softening lifts every tile lighter
    /// (esp. in light mode), so the safeguard is strengthened (0.25→0.38 opacity,
    /// radius 2→3) to keep the white ring + value legible on the now-softer tiles
    /// without un-softening the gradient itself. Still a single soft touch — premium.
    nonisolated static let shadowColor: Color = .black.opacity(0.38)
    nonisolated static let shadowRadius: CGFloat = 3
    nonisolated static let shadowYOffset: CGFloat = 1
}

/// Applies the ``WellnessRingPalette`` legibility shadow to a ring ONLY on the
/// coloured gradient tiles (`active`). Off (`active == false`) on the plain mono
/// fallback so the standard ring stays shadow-free. A soft, single-touch dark
/// shadow — keeps the white fill + value premium where the gradient's lightest
/// corner would otherwise wash them out.
struct WellnessRingShadow: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.shadow(
                color: WellnessRingPalette.shadowColor,
                radius: WellnessRingPalette.shadowRadius,
                y: WellnessRingPalette.shadowYOffset
            )
        } else {
            content
        }
    }
}
