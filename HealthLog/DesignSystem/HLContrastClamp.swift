import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// Guaranteed-contrast helper for accent-tinted foregrounds — **REG-BTN
/// (2026-05-22, v0.5.5 button + text contrast follow-up to REG-13).**
///
/// **Hintergrund:**
/// Operator-Feedback after the REG-13 toggle fix:
/// *"Buttons funktionieren immer noch nicht mit dunkel und weiss. Da ist
/// dann alles weiss. Auch bei Text ist das ein Problem."* — same root
/// cause as REG-13. Several `HLTint` picks resolve to near-canvas
/// luminance in one of the two appearances:
///
/// - `HLTint.schwarz` → `UIColor.label` (off-white `#EBEBF5` in Dark) →
///   collapses against `HLSurface.primary` Dark canvas (`#101113`)? no —
///   reverse: light text on dark canvas reads, **but** the same colour
///   used as a primary-CTA FILL with white text yields white-on-white.
/// - `HLTint.weiss` → `UIColor.secondaryLabel` (muted graphite) — used
///   as foreground on a transparent secondary button against a graphite
///   canvas collapses to graphite-on-graphite.
/// - `HLTint.cyan` → `#8BE9FD` — when used as text on `HLSurface.primary`
///   Light (`#F7F7F8`), contrast falls below WCAG 4.5:1.
///
/// **WCAG 2.1 SC 1.4.3 (Contrast Minimum):** normal-weight text requires
/// at least 4.5:1 luminance ratio against its background. UI components
/// (SC 1.4.11) require 3:1 — so we use 4.5:1 as the floor for text-bearing
/// surfaces (button labels, hyperlinks) and accept the same threshold for
/// the icon-only surfaces in the same sweep (over-shoot is harmless).
///
/// **API:** call `HLContrastClamp.clampedAccent(_: tint, against: surface, in: scheme)`
/// to receive either the tint OR a high-contrast fallback (`HLText.primary`)
/// when the contrast ratio against the named surface falls below 4.5:1.
/// Surface is sampled per `ColorScheme` so the same helper works in both
/// appearances. Call-site sugar: `Color.clampedForCanvas(in:)` wraps the
/// `against: .canvas` case for the common contrast-trap surface.
///
/// **Single chokepoint:** screens never re-implement the clamp logic —
/// they consume the helper. New code that paints accent-tinted text on
/// canvas / secondary surfaces should route through `clampedAccent(...)`
/// rather than `.foregroundStyle(.tint)` directly when contrast is at risk.
///
/// **Concurrency (v0.6.0.6):** annotated `@MainActor` — every method
/// reaches into `UIColor(_:)` and `getRed(...)` which resolve dynamic
/// trait collections on the main actor under iOS 18+. Every current
/// call-site is already MainActor-bound (HLButton body, SwiftUI views,
/// `@MainActor`-annotated test suite). Making the contract explicit
/// here prevents a future off-MainActor caller from triggering a
/// hard-to-diagnose data race.
@MainActor
public enum HLContrastClamp {
    /// WCAG 2.1 SC 1.4.3 — minimum luminance ratio for normal-weight text.
    public static let wcagAATextRatio: Double = 4.5

    /// WCAG 2.1 SC 1.4.11 — minimum luminance ratio for UI components and
    /// graphical objects. Used for the hairline-border sanity floor when
    /// the accent is purely decorative.
    public static let wcagAAUIRatio: Double = 3.0

    /// Named app surfaces the clamp can sample against. Internally maps to
    /// concrete `Color` per `ColorScheme` so the call-site stays
    /// declarative.
    public enum Surface {
        case canvas // HLSurface.primary
        case card // HLSurface.secondary
    }

    /// Returns the candidate `Color` if it clears the WCAG AA text ratio
    /// (4.5:1) against the named surface in the given appearance, OR a
    /// high-contrast fallback (`HLText.primary` resolved for the scheme)
    /// otherwise.
    ///
    /// Use for text-bearing accent foregrounds (secondary/ghost button
    /// labels, hyperlinks, "Mehr anzeigen"-style CTAs).
    public static func clampedAccent(
        _ candidate: Color,
        against surface: Surface,
        in scheme: ColorScheme
    ) -> Color {
        #if canImport(UIKit)
            let bgUIColor = uiColor(for: surface, scheme: scheme)
            let fgUIColor = UIColor(candidate)
            let ratio = contrastRatio(foreground: fgUIColor, background: bgUIColor)
            if ratio >= wcagAATextRatio {
                return candidate
            }
            return fallback(scheme: scheme)
        #else
            return candidate
        #endif
    }

    // Computes the WCAG 2.1 luminance-contrast ratio between two colours.
    // Returns a value in `[1, 21]`. White-on-black yields ~21, identical
    // colours yield 1.
    //
    // Implements the formula from WCAG 2.1 §1.4.3:
    // `(L1 + 0.05) / (L2 + 0.05)` where `L1 > L2` are relative luminance.
    #if canImport(UIKit)
        public static func contrastRatio(foreground: UIColor, background: UIColor) -> Double {
            let lFg = relativeLuminance(foreground)
            let lBg = relativeLuminance(background)
            let lighter = max(lFg, lBg)
            let darker = min(lFg, lBg)
            return (lighter + 0.05) / (darker + 0.05)
        }

        /// WCAG 2.1 relative-luminance formula. Linearises each sRGB channel
        /// then applies the `0.2126 R + 0.7152 G + 0.0722 B` weighting.
        private static func relativeLuminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            func channel(_ c: CGFloat) -> Double {
                let v = Double(c)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        private static func uiColor(for surface: Surface, scheme: ColorScheme) -> UIColor {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let swiftUIColor: Color = switch surface {
            case .canvas: HLSurface.primary
            case .card: HLSurface.secondary
            }
            return UIColor(swiftUIColor).resolvedColor(with: traits)
        }

        private static func fallback(scheme: ColorScheme) -> Color {
            // `HLText.primary` is itself a dark-mode-aware asset; we return
            // the SwiftUI Color so callers stay in the SwiftUI colour space.
            HLText.primary
        }
    #else
        private static func fallback(scheme: ColorScheme) -> Color {
            HLText.primary
        }
    #endif
}

public extension Color {
    /// Convenience: clamp this accent against the canvas surface for the
    /// given scheme. Use at call-sites that paint accent text on top of
    /// `HLSurface.primary` (canvas) — the most common contrast trap.
    ///
    /// `@MainActor` per `HLContrastClamp.clampedAccent(...)` — see the
    /// type-level annotation rationale.
    @MainActor
    func clampedForCanvas(in scheme: ColorScheme) -> Color {
        HLContrastClamp.clampedAccent(self, against: .canvas, in: scheme)
    }
}
