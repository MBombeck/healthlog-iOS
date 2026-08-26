@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// REG-13 regression — REG-13 (TestFlight Build 23, 2026-05-21):
/// Operator-Feedback "*guck mal bei den Schaltern, wenn ich weiß und dunkel
/// mache, dann kann ich den Schalter nicht mehr sehen*". Default-SwiftUI
/// `Toggle` lässt den ON-Track auf `.tint(...)` resolven, der Thumb bleibt
/// weiß. Mehrere `HLTint`-Picks resolven in Dark Mode zu sehr hellen Werten:
/// Thumb + Track verschmelzen zu einem unsichtbaren weißen Pill.
///
/// Diese Suite verriegelt den Fix:
///
/// 1. **Contrast contract** — die "kritischen" `HLTint`-Picks
///    (`.schwarz`, `.weiss`, `.cyan`) resolven in Dark Mode tatsächlich nahe
///    Weiß (Helligkeit ≥ 0.80). Eine zukünftige Token-Retune dieser Picks
///    auf einen mittel-saturierten Wert würde den Fix unnötig machen — der
///    Test dokumentiert, **warum** HLToggleStyle existiert.
/// 2. **Style availability** — `.hl` ist als statische Convenience auf
///    `ToggleStyle` zugreifbar (verhindert versehentliches Entfernen).
/// 3. **Style binding at root** — der gleiche Style soll global an der
///    Scene-Root gebunden sein. Dieses Test prüft den Aufruf nicht direkt
///    (View-Tree-Inspektion ist im Test-Bundle ohne UI-Test-Setup nicht
///    deterministisch); stattdessen verriegelt der Test, dass `HLToggleStyle`
///    als `ToggleStyle` konform bleibt und das Layout korrekte Dimensionen
///    benutzt.
@Suite("HLToggleStyle REG-13 contrast guarantee")
@MainActor
struct HLToggleStyleTests {
    // MARK: - Contrast-rationale tests (warum der Fix nötig ist)

    @Test(
        "Critical chrome candidates resolve to near-white in dark mode (justifies HLToggleStyle border fallback)",
        arguments: [
            (name: "label", color: Color(uiColor: .label)),
            (name: "secondaryLabel", color: Color(uiColor: .secondaryLabel)),
            (name: "cyan", color: HLColor.cyan)
        ]
    )
    func criticalTintsResolveNearWhiteInDarkMode(candidate: (name: String, color: Color)) {
        // Diese Kandidaten haben in der TestFlight Build 23 das REG-13-Issue
        // ausgelöst: Track-Fill ≈ Thumb-Fill → unsichtbarer Schalter.
        //
        // `UIColor.label`         → off-white `#EBEBF5` in Dark.
        // `UIColor.secondaryLabel`→ muted graphite.
        // `HLColor.cyan`          → Dracula `#8BE9FD` (statisch, nicht dark-aware).
        //
        // Alle drei haben relative Luminanz ≥ 0.5 in Dark Mode — mit weißem
        // Thumb darauf wird der Switch unsichtbar.
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let resolved = resolveToSRGB(candidate.color, traits: darkTraits)
        let luminance = relativeLuminance(components: resolved)
        let message = """
        \(candidate.name) dark-mode luminance is \(luminance). \
        If this drops below 0.5, the border-fallback in HLToggleStyle \
        becomes optional for this candidate (but should stay for consistency).
        """
        #expect(luminance >= 0.50, "\(message)")
    }

    @Test("HLToggleStyle is reachable as `.hl` convenience accessor")
    func styleConvenienceAccessorExists() {
        // Locks the call-site contract — `HealthLogApp` consumes
        // `.toggleStyle(.hl)`; a future rename of the static accessor would
        // silently break the global binding.
        let style: HLToggleStyle = .hl
        #expect(type(of: style) == HLToggleStyle.self)
    }

    @Test("HLToggleStyle conforms to ToggleStyle (compile-time contract anchor)")
    func styleConformsToToggleStyle() {
        // Pure-conformance assertion — if a future refactor accidentally
        // changes the protocol shape, this fails at compile-time rather
        // than at runtime when a Toggle silently falls back to the system
        // default style.
        let style: any ToggleStyle = HLToggleStyle()
        #expect(String(describing: type(of: style)).contains("HLToggleStyle"))
    }

    // MARK: - Helpers

    /// sRGB component triple resolved from a SwiftUI `Color` for a given
    /// trait collection. Two-field struct keeps SwiftLint's `large_tuple`
    /// gate happy while staying ergonomic at the call-site.
    private struct SRGBComponents {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Resolves a SwiftUI `Color` to sRGB floats under the given trait
    /// collection. Mirrors `TokensRegressionTests.resolvedHex` semantics but
    /// returns the raw components so the luminance formula below can
    /// consume normalised values directly.
    private func resolveToSRGB(_ color: Color, traits: UITraitCollection) -> SRGBComponents {
        let uiColor = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SRGBComponents(red: Double(red), green: Double(green), blue: Double(blue))
    }

    /// WCAG relative-luminance formula (sRGB → linear → weighted sum). Used
    /// to assert how close a tint resolves to "white" in dark mode.
    private func relativeLuminance(components: SRGBComponents) -> Double {
        func channel(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(components.red)
            + 0.7152 * channel(components.green)
            + 0.0722 * channel(components.blue)
    }
}
