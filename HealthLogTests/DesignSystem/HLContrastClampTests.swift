@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// Anchors the v0.6.0.5 REG-BTN contrast clamp so a future tweak to
/// `HLContrastClamp.clampedAccent` (threshold, surface mapping, fallback
/// colour) flags loudly instead of silently regressing the white-on-white
/// / black-on-black accent foregrounds Operator hit on the live build.
///
/// Strategy: assert the **post-clamp output invariant** — the helper's
/// returned colour MUST clear the WCAG 4.5:1 ratio against the surface
/// it was clamped against, regardless of whether the candidate passed or
/// the fallback fired. That's the contract callers depend on.
///
/// Why not assert candidate-vs-fallback identity directly: `UIColor`
/// equality is colour-space-sensitive (monochrome `UIColor.label` vs the
/// sRGB `HLText.primary` asset never `==` even at identical luminance);
/// comparing through the *ratio* is colour-space-stable.
///
/// `Color → UIColor` resolution requires the main actor under iOS 18; the
/// suite is `@MainActor` to keep the trait-collection sampling inside
/// `HLContrastClamp.contrastRatio` safe.
@MainActor
@Suite("HLContrastClamp WCAG boundary regression")
struct HLContrastClampTests {
    // MARK: - Helpers

    private func resolved(_ color: Color, in scheme: ColorScheme) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(
            userInterfaceStyle: scheme == .dark ? .dark : .light
        ))
    }

    private func ratioAgainstCanvas(_ candidate: Color, in scheme: ColorScheme) -> Double {
        let fg = resolved(candidate, in: scheme)
        let bg = resolved(HLSurface.primary, in: scheme)
        return HLContrastClamp.contrastRatio(foreground: fg, background: bg)
    }

    /// Post-clamp invariant: the returned colour's ratio against the
    /// canvas surface in the given scheme must be ≥ 4.5:1. This is the
    /// guarantee the helper exists to provide; failing it means the
    /// fallback colour itself is somehow sub-AA — which would be a much
    /// deeper bug.
    private func clampedRatio(_ candidate: Color, in scheme: ColorScheme) -> Double {
        let clamped = HLContrastClamp.clampedAccent(candidate, against: .canvas, in: scheme)
        return ratioAgainstCanvas(clamped, in: scheme)
    }

    // MARK: - Tests

    @Test("cyan candidate fails 4.5:1 on light canvas — clamp output still passes")
    func cyanOnLightCanvasClampedToReadable() {
        // Dracula `cyan` = `#8BE9FD`. Its luminance is high enough that the
        // candidate ratio against the near-white `HLSurface.primary` light
        // canvas sinks under 4.5:1 — the Operator-reported "cyan unreadable
        // on light" anchor from the v0.5.5 walkthrough. The clamp must
        // either echo the candidate (it doesn't here, ratio fails) OR fall
        // back to `HLText.primary`; either way the **output** must clear
        // 4.5:1 against the canvas.
        let candidate = HLColor.cyan
        let candidateRatio = ratioAgainstCanvas(candidate, in: .light)
        let outputRatio = clampedRatio(candidate, in: .light)
        #expect(
            candidateRatio < HLContrastClamp.wcagAATextRatio,
            "cyan candidate ratio = \(candidateRatio) — must be sub-AA to exercise the fallback"
        )
        #expect(
            outputRatio >= HLContrastClamp.wcagAATextRatio,
            "clamp output ratio = \(outputRatio) — must clear AA"
        )
    }

    @Test("passing candidate on dark canvas — clamp echoes through")
    func passingCandidateOnDarkCanvasEchoes() {
        // The monochrome ink `HLText.primary` sits firmly above 4.5:1 against
        // the dark canvas (`#101113`). The clamp must NOT swap a candidate that
        // already clears AA — it paints through verbatim.
        let candidate = HLText.primary
        let candidateRatio = ratioAgainstCanvas(candidate, in: .dark)
        let outputRatio = clampedRatio(candidate, in: .dark)
        #expect(
            candidateRatio >= HLContrastClamp.wcagAATextRatio,
            "candidate ratio = \(candidateRatio) — must pass AA"
        )
        // When the candidate passes, the helper returns it verbatim — the
        // output ratio equals the candidate ratio. We assert numerical
        // equality (with a small tolerance for sRGB-linearisation rounding)
        // rather than colour identity, side-stepping the colour-space
        // equality trap.
        #expect(
            abs(outputRatio - candidateRatio) < 0.01,
            "candidate must pass through unchanged (out = \(outputRatio), in = \(candidateRatio))"
        )
    }

    @Test("schwarz against canvas reads ≥ AA in both modes after clamp")
    func schwarzCanvasClampedReadable() {
        // `.schwarz` resolves to `UIColor.label` — near-black in light mode,
        // near-white in dark mode. As a text-on-canvas pair this is the
        // system's own high-contrast anchor: WCAG ratio is well above 4.5:1
        // in either appearance. The clamp's output must clear AA in both.
        let candidate = Color(uiColor: .label)
        let lightOut = clampedRatio(candidate, in: .light)
        let darkOut = clampedRatio(candidate, in: .dark)
        #expect(lightOut >= HLContrastClamp.wcagAATextRatio, "schwarz light → \(lightOut)")
        #expect(darkOut >= HLContrastClamp.wcagAATextRatio, "schwarz dark → \(darkOut)")
    }

    @Test("weiss against canvas reads ≥ AA in both modes after clamp")
    func weissCanvasClampedReadable() {
        // `.weiss` resolves to `UIColor.secondaryLabel` — a graphite mid-
        // tone (~60% white opacity over the system canvas). The candidate
        // ratio against `HLSurface.primary` lands ~10:1 in light (passes)
        // and similarly in dark (passes) — so the clamp echoes through.
        // The visible Operator REG-BTN collapse for `.weiss` lives at the
        // primary-CTA *fill* layer (white text on a near-white fill), not
        // here at the text-on-canvas layer. This test pins the canvas-
        // layer invariant; the fill-layer fix lives in `HLButton.swift`.
        let candidate = Color(uiColor: .secondaryLabel)
        let lightOut = clampedRatio(candidate, in: .light)
        let darkOut = clampedRatio(candidate, in: .dark)
        #expect(lightOut >= HLContrastClamp.wcagAATextRatio, "weiss light → \(lightOut)")
        #expect(darkOut >= HLContrastClamp.wcagAATextRatio, "weiss dark → \(darkOut)")
    }

    @Test("contrastRatio: black on white ≈ 21:1 (WCAG textbook boundary)")
    func contrastRatioBlackOnWhite() {
        // WCAG 2.1 §1.4.3 textbook anchor: pure black on pure white = 21:1.
        // A small numerical tolerance allows for sRGB-linearisation rounding.
        let ratio = HLContrastClamp.contrastRatio(foreground: .black, background: .white)
        #expect(ratio > 20.9 && ratio < 21.1, "black on white ≈ 21:1, got \(ratio)")
    }

    @Test("contrastRatio: identical colours collapse to 1:1")
    func contrastRatioIdenticalColours() {
        // Lower bound of the formula: identical foreground / background =
        // exactly 1:1. The white-on-white / black-on-black collapse mode
        // that the clamp guards against.
        let ratio = HLContrastClamp.contrastRatio(foreground: .white, background: .white)
        #expect(ratio > 0.99 && ratio < 1.01, "identical colours ≈ 1:1, got \(ratio)")
    }

    @Test("wcagAATextRatio threshold matches WCAG 2.1 SC 1.4.3 (4.5:1)")
    func textRatioThresholdAnchor() {
        // Lock the public threshold so a refactor doesn't accidentally
        // drop the floor to 3:1 (UI-component ratio) and re-introduce
        // sub-AA text contrast across every accent foreground.
        #expect(HLContrastClamp.wcagAATextRatio == 4.5)
        #expect(HLContrastClamp.wcagAAUIRatio == 3.0)
    }

    @Test("clampedForCanvas extension matches the explicit helper call")
    func extensionParity() {
        // The `Color.clampedForCanvas(in:)` extension is the call-site
        // sugar that screens use day-to-day. The output ratio it produces
        // must match the explicit `HLContrastClamp.clampedAccent(...)`
        // call — otherwise call-sites drift silently.
        let candidate = HLColor.cyan
        let direct = HLContrastClamp.clampedAccent(candidate, against: .canvas, in: .light)
        let viaExtension = candidate.clampedForCanvas(in: .light)
        let directRatio = ratioAgainstCanvas(direct, in: .light)
        let extensionRatio = ratioAgainstCanvas(viaExtension, in: .light)
        #expect(
            abs(directRatio - extensionRatio) < 0.01,
            "direct = \(directRatio), extension = \(extensionRatio)"
        )
    }

    @Test("clamp output never drops below AA — universal invariant")
    func clampOutputAlwaysClearsAA() {
        // The whole point of the helper: regardless of the candidate colour,
        // the returned colour clears 4.5:1 against the surface it was clamped
        // against. Sweep a representative set of candidates (the former
        // accent-swatch palette + the monochrome ink) in both schemes; a
        // single drop below AA is a regression we want to know about
        // immediately.
        let candidates: [(name: String, color: Color)] = [
            ("cyan", HLColor.cyan),
            ("orange", HLColor.orange),
            ("green", HLColor.green),
            ("systemBlue", Color.blue),
            ("schwarz", Color(uiColor: .label)),
            ("weiss", Color(uiColor: .secondaryLabel)),
            ("primary", HLText.primary)
        ]
        for candidate in candidates {
            for scheme in [ColorScheme.light, .dark] {
                let ratio = clampedRatio(candidate.color, in: scheme)
                #expect(
                    ratio >= HLContrastClamp.wcagAATextRatio,
                    "\(candidate.name) on \(scheme == .dark ? "dark" : "light") = \(ratio)"
                )
            }
        }
    }
}
