import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// **v0.8.5 WFIX-LA — canonical design tokens for the widget extension.**
///
/// Shared source-membership file (compiled into BOTH `HealthLog` and
/// `HealthLogWidgets`). The widget extension cannot resolve the app's
/// asset-catalog colour-sets (`Color("TextPrimaryMono", bundle: .main)`
/// resolves against the *extension* bundle, which ships no asset catalog),
/// so the app's `HLText` / `HLSurface` / `HLColor.statusOK` tokens render
/// wrong (or fall back to clear) inside the Live Activity + widgets.
///
/// This file replicates the **documented, operator-locked** HealthLog
/// design-system palette — Withings-style Tonal-Mono with status colours
/// as signal-only — as code-level dynamic colours that work identically in
/// both targets without an asset catalog. The light slots follow the
/// v0.14.11 "Warmes Papier" light-theme redesign; the widget uses the
/// *effective* (alpha-composited) ink so it matches what the app paints:
///
/// - **Text primary:** `#42403C` light (the app's `#2E2B27 @ 0.90` composited
///   over the warm card) / `#EBEBF5` dark (`HLText.primary`).
/// - **Text secondary:** `UIColor.secondaryLabel` (system-tuned for
///   legibility on either scheme).
/// - **Card surface:** `#FAF8F5` light / `#1A1B1F` dark (`HLSurface.secondary`).
/// - **Status OK (taken):** `#2B774B` light / `#50FA7B` dark (`HLColor.statusOK`).
/// - **Status warn (snoozed):** `#9B5D10` light / `#FFB86C` dark
///   (`HLColor.statusWarn`).
///
/// **No Dracula.** The prior `LAColor` shipped the Dracula purple
/// `#BD93F9` accent + `#282A36` background, which the app abandoned in the
/// v0.8.1 monochrome-restore (chrome = monochrome, accent is signal-only).
/// The accent here is therefore the monochrome primary text colour, not a
/// hue — exactly as `HLAccent.primary` / `HLChartTints.series` resolve in
/// the app.
enum LAColor {
    /// Brand/chrome accent — **monochrome** (matches `HLAccent.primary` →
    /// `HLText.primary`). Used for the pill glyph, the Dynamic-Island
    /// keyline, and the "Taken" button tint. Carries no hue.
    static let accent = textPrimary

    /// Success signal — the dose-taken confirmation tick (matches
    /// `HLColor.statusOK`). The one place a colour is allowed: a real
    /// status signal, per the design-system contract.
    static let success = statusOK

    /// Snoozed / warning signal (matches `HLColor.statusWarn`).
    static let warn = statusWarn

    /// Overdue / severity signal — the one place the loved countdown carries
    /// colour: once the dose is past-due the timer turns red (matches
    /// `HLColor.statusBad`). Signal-only, handbook-compliant severity callout.
    static let danger = statusBad

    /// Primary text / metric values (`HLText.primary`).
    static let text = textPrimary

    /// Secondary text — captions, meta, units (`HLText.secondary`).
    static let textSecondary = textSecondaryColor

    /// Card / Live-Activity surface backing (`HLSurface.secondary`):
    /// pure white in light, lifted-charcoal in dark.
    static let surface = surfaceCard

    // MARK: - Dynamic colour primitives (light/dark, asset-catalog-free)

    /// A plain sRGB triple — kept as a named type (not a tuple) so the
    /// light/dark pairs stay readable and lint-clean.
    private struct RGB {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private static let textPrimary = dynamic(
        light: RGB(red: 0x42, green: 0x40, blue: 0x3C),
        dark: RGB(red: 0xEB, green: 0xEB, blue: 0xF5)
    )

    private static let surfaceCard = dynamic(
        light: RGB(red: 0xFA, green: 0xF8, blue: 0xF5),
        dark: RGB(red: 0x1A, green: 0x1B, blue: 0x1F)
    )

    private static let statusOK = dynamic(
        light: RGB(red: 0x2B, green: 0x77, blue: 0x4B),
        dark: RGB(red: 0x50, green: 0xFA, blue: 0x7B)
    )

    private static let statusWarn = dynamic(
        light: RGB(red: 0x9B, green: 0x5D, blue: 0x10),
        dark: RGB(red: 0xFF, green: 0xB8, blue: 0x6C)
    )

    /// Overdue / severity red (`HLColor.statusBad` colorset hex):
    /// `#B23E3B` light / `#FF5555` dark.
    private static let statusBad = dynamic(
        light: RGB(red: 0xB2, green: 0x3E, blue: 0x3B),
        dark: RGB(red: 0xFF, green: 0x55, blue: 0x55)
    )

    /// Secondary text resolves through the system semantic colour so it
    /// stays legible on either scheme without a hand-tuned pair — exactly
    /// what `HLText.secondary` (~70 % primary) is calibrated against.
    private static let textSecondaryColor: Color = {
        #if canImport(UIKit)
            Color(uiColor: .secondaryLabel)
        #else
            Color.secondary
        #endif
    }()

    /// Build a scheme-aware `Color` from an explicit light/dark RGB pair.
    /// Uses a `UIColor` dynamic provider so it resolves correctly in the
    /// widget-extension process (which has no asset catalog to read).
    private static func dynamic(light: RGB, dark: RGB) -> Color {
        #if canImport(UIKit)
            Color(uiColor: UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat(rgb.red) / 255,
                    green: CGFloat(rgb.green) / 255,
                    blue: CGFloat(rgb.blue) / 255,
                    alpha: 1
                )
            })
        #else
            Color(
                .sRGB,
                red: Double(light.red) / 255,
                green: Double(light.green) / 255,
                blue: Double(light.blue) / 255,
                opacity: 1
            )
        #endif
    }
}

/// **v0.14 b146 — the canonical widget/Live-Activity "Taken" pill.**
///
/// One source of truth for the dose-confirmation CTA across the widget
/// extension. Previously the `NextDoseWidget` rolled `.tint(LAColor.accent) +
/// .buttonStyle(.borderedProminent)`, which in dark mode paints the near-white
/// accent as the FILL and auto-derives a white label → invisible white-on-white.
/// `.borderedProminent` has no environment tint-clamp in the extension process,
/// so it must never be used for widget CTAs. This modifier reproduces the
/// `MedicationLiveActivityWidget.TakenButton` construction (explicit fill / text
/// / border, `.buttonStyle(.plain)`) and honours the same armed (pending-confirm)
/// two-state, so the contrast never collapses in either appearance.
struct LAMedTakenPillStyle: ViewModifier {
    /// `true` = the armed "Bestätigen?" state (outline + accent label on a faint
    /// fill); `false` = the resting "Genommen" state (accent fill + surface label).
    let pendingConfirm: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .foregroundStyle(pendingConfirm ? LAColor.accent : LAColor.surface)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(pendingConfirm ? LAColor.accent.opacity(0.12) : LAColor.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        pendingConfirm ? LAColor.accent : LAColor.text.opacity(0.18),
                        lineWidth: pendingConfirm ? 1.5 : 1
                    )
            )
    }
}

extension View {
    /// Applies the canonical widget/Live-Activity "Taken" pill (see
    /// ``LAMedTakenPillStyle``). Pair with `.buttonStyle(.plain)` on the button.
    func laMedTakenPill(pendingConfirm: Bool) -> some View {
        modifier(LAMedTakenPillStyle(pendingConfirm: pendingConfirm))
    }
}
