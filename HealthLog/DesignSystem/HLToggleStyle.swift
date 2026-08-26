import SwiftUI

/// Toggle-Style mit **garantiertem Kontrast** in Light + Dark — unabhängig vom
/// User-Akzent.
///
/// **Hintergrund (REG-13, 2026-05-21 TestFlight Build 23):**
/// Operator-Feedback "*guck mal bei den Schaltern, wenn ich weiß und dunkel
/// mache, dann kann ich den Schalter nicht mehr sehen*". Default-SwiftUI
/// `Toggle` lässt den ON-Track auf `.tint(...)` resolven; der Thumb bleibt
/// weiß. In Dark Mode wird das zum Problem, weil mehrere `HLTint`-Picks zu
/// sehr nahe an Weiß rendern und damit Thumb + Track als ein einziges weißes
/// Pill verschmelzen:
///
/// - `HLTint.schwarz` → `UIColor.label` (≈ off-white `#EBEBF5` in Dark)
/// - `HLTint.weiss`   → `UIColor.secondaryLabel` (gedämpftes Hellgrau)
/// - `HLTint.cyan`    → `#8BE9FD` (Dracula-Cyan, ebenfalls sehr hell)
///
/// In allen drei Fällen liegt der Track-on-Wert in Dark Mode innerhalb
/// einiger ΔE-Schritte vom weißen Thumb → der Schalter wirkt unsichtbar /
/// nicht anwählbar.
///
/// **Lösung:** eigener `ToggleStyle`, der das Standard-iOS-Layout (51×31 pt
/// Capsule mit 27 pt Thumb) reproduziert, dabei aber:
///
/// 1. Eine **Hairline-Border** (`HLText.tertiary @ 35 %`) auf dem Track,
///    sowohl ON als auch OFF. Garantiert, dass der Schalter immer ein
///    sichtbares Rechteck im Card-Surface ist — auch wenn Track-Fill und
///    Card-Background numerisch identisch wären.
/// 2. Eine **Thumb-Border** (`HLText.tertiary @ 25 %`), damit der Thumb sich
///    auch dann vom Track abhebt, wenn beide zufällig hell sind.
/// 3. Off-Track-Farbe = `HLSurface.tertiary` (mono recessed well) statt
///    `Color(.systemFill)` — bleibt im Theme-2.0 Tonal-Mono-Kontrakt.
///
/// **v0.6.1.10 Y9-F update:** ON-Track-Fill war an `HLText.secondary` gepinnt
/// (statt der App-root-`.tint(HLText.primary)`), weil der near-white Thumb auf
/// dem near-white ON-Track in Dark Mode zu einem unsichtbaren Pill verschmolz.
///
/// **QoL-A2 / Felt-craft #1 (2026-06-02):** Die hand-gerollte Switch-Nachbildung
/// (eigene Capsule + Thumb, `.onTapGesture` + ungated Spring) warf native
/// Switch-Semantik weg — Drag-to-toggle, Focus, volle AX-Traits über
/// `.isSelected` hinaus, und das systemeigene Reduce-Motion-Handling. Das ist
/// genau der „kein Custom außer wo Apple zwingt“-Verstoß, den ein
/// Award-Reviewer flaggt.
///
/// Lösung: `makeBody` rendert jetzt einen **nativen** `Toggle` mit
/// `.toggleStyle(.switch)` und `.labelsHidden()`, gepinnt auf
/// `.tint(HLText.secondary)`. Damit kommen native Drag/Focus/A11y + die
/// systemeigene Reduce-Motion-gegateter Switch-Animation zurück, während der
/// REG-13-Fix (mono `HLText.secondary` ON-Track, garantiert sichtbar gegen den
/// weißen Thumb in Light + Dark, unabhängig von der App-root-`.tint`) erhalten
/// bleibt. Das Label-Layout (Label links, Switch rechts, elastischer Spacer)
/// bleibt identisch.
struct HLToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            // Label-Slot: SwiftUI-Standard-Layout (Label links, Switch rechts,
            // dazwischen elastischer Spacer). `Toggle` ohne Label rendert das
            // Slot leer, was den Switch wie gewohnt rechtsbündig hält.
            configuration.label
            Spacer(minLength: 0)
            // Nativer Switch — volle Drag/Focus/A11y + system-eigenes
            // Reduce-Motion-Handling. `.labelsHidden()`, weil das Label oben
            // bereits gerendert ist. `.tint(HLText.secondary)` hält den
            // ON-Track mono und garantiert sichtbar gegen den weißen Thumb
            // (REG-13), unabhängig von der App-root-`.tint(HLText.primary)`.
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(HLText.secondary)
        }
    }
}

// MARK: - ToggleStyle convenience accessor

extension ToggleStyle where Self == HLToggleStyle {
    /// Komfort-Accessor — `.toggleStyle(.hl)` statt
    /// `.toggleStyle(HLToggleStyle())`. Wird einmal in `HealthLogApp` an der
    /// Scene-Root gesetzt und vererbt sich an jeden Toggle in der View-Tree.
    static var hl: HLToggleStyle {
        HLToggleStyle()
    }
}
