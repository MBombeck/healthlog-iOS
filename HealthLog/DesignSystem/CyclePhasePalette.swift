import SwiftUI

/// **Phase C5 — warm phase-tint tokens for the native cycle ring (`HLCycleRing`).**
///
/// The app is strictly MONOCHROME (ink / graphite / grey, see `HLColor` /
/// `HLText`). The four menstrual-cycle phase tints are the **only** sanctioned
/// chroma on the cycle surface, and they are deliberately restrained: low-chroma,
/// organic, warm — clay / honey / rose / mauve, never candy. They sit
/// harmoniously over the monochrome track ring on both the near-black dark canvas
/// (`HLSurface.primary` dark `#101113`) and the warm-grey light canvas
/// (`#F7F7F8`).
///
/// **Why code literals, not asset-catalog colorsets.** This phase ships as a
/// standalone, previewable component without touching the asset catalog or
/// `project.yml`. Each tint therefore resolves light/dark via an explicit
/// `colorScheme` switch (the caller passes `colorScheme` in). The hex values are
/// pinned here so a future migration to `*.colorset` is a pure asset-layer move.
///
/// **Chroma discipline.** Light-mode tints are mid-saturation, mid-luminance so
/// they read on white without glowing. Dark-mode tints are pulled lighter +
/// slightly desaturated so they lift off the near-black canvas without becoming
/// neon. Ovulatory (the fertile peak) is intentionally the brightest / warmest
/// of the four; luteal is the most muted (dusty taupe-mauve) so the run-up to the
/// next period reads as a calm wind-down.
public enum CyclePhasePalette {
    /// The four canonical cycle phases (mirrors
    /// `CyclePredictionEngine.CyclePhase` casing 1:1, but kept local so the pure
    /// component carries no model dependency).
    public enum Phase: Sendable, Equatable, CaseIterable {
        case menstrual
        case follicular
        case ovulatory
        case luteal
    }

    // MARK: - Light-mode hexes (mid-saturation, legible on warm white)

    /// menstrual — muted terracotta / clay
    private static let menstrualLight = Color(hex: 0xC2674F)
    /// follicular — honey / soft amber
    private static let follicularLight = Color(hex: 0xD2A24C)
    /// ovulatory — warm rose / coral (the peak, slightly brighter)
    private static let ovulatoryLight = Color(hex: 0xD96F73)
    /// luteal — dusty mauve / taupe (the calm wind-down)
    private static let lutealLight = Color(hex: 0xA98BA0)

    // MARK: - Dark-mode hexes (lifted + desaturated, lift off near-black)

    /// menstrual — warmer, lighter clay so it glows softly on charcoal
    private static let menstrualDark = Color(hex: 0xD98069)
    /// follicular — soft honey, pulled lighter
    private static let follicularDark = Color(hex: 0xE0B669)
    /// ovulatory — warm rose, the brightest of the four
    private static let ovulatoryDark = Color(hex: 0xE88B8F)
    /// luteal — dusty mauve, lifted but kept the most muted
    private static let lutealDark = Color(hex: 0xBBA0B5)

    /// The phase's warm tint for the given appearance. Light + dark are tuned
    /// separately so the arc reads harmoniously on either canvas.
    public static func tint(for phase: Phase, scheme: ColorScheme) -> Color {
        switch (phase, scheme) {
        case (.menstrual, .dark): menstrualDark
        case (.menstrual, _): menstrualLight
        case (.follicular, .dark): follicularDark
        case (.follicular, _): follicularLight
        case (.ovulatory, .dark): ovulatoryDark
        case (.ovulatory, _): ovulatoryLight
        case (.luteal, .dark): lutealDark
        case (.luteal, _): lutealLight
        }
    }

    /// A softened companion of the phase tint for halos / glows / fertile bands —
    /// the same hue at reduced alpha so secondary chrome never competes with the
    /// primary arc.
    public static func soft(for phase: Phase, scheme: ColorScheme, opacity: Double = 0.30) -> Color {
        tint(for: phase, scheme: scheme).opacity(opacity)
    }
}
