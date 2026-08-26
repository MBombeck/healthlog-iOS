import SwiftUI

// Sheet presentation tokens now live in `HLSheet.swift` (HLSheetSize + the
// `hlSheetPresentation(_:)` modifier alongside the legacy `HLSheet` aliases).

// MARK: - Asset-Catalog tinted aliases (v0.4.0 §A6 retune)

public extension Color {
    /// Canonical screen background — `Background.colorset`, retuned to
    /// `#F5F5F8 / #16171C` (A6 §4). Use via `.hlScreenBackground()` modifier.
    static let hlBackground = HLColor.background
    /// Elevated background platter for List rows etc.
    static let hlBackgroundElevated = HLColor.backgroundEleva
    /// Card / surface base (HLCard backing).
    static let hlSurface = HLColor.surface
    /// Hero / elevated surface (HLCard.elevated backing).
    static let hlSurfaceElevated = HLColor.surfaceElevated
}

// MARK: - Theme-2.0 Tonal-Mono surface + text scale (T2-1 Foundation, 2026-05-16)

//
// Operator walkthrough verdict on Wave-Therapy (`therapy-interim-merged`):
// "Dracula passt halt gar nicht mehr. Akzentfarbe nach wie vor zu viel. Es muss
// einfach mehr clean aussehen." Theme-2.0 = Withings-Style Tonal-Mono with a
// single Dracula-Purple accent for CTAs only.
//
// This namespace is the new source of truth for surface + text resolution.
// T2-1 introduces the tokens additively so existing primitives (asset-catalog
// `HLColor.background` etc.) keep compiling; T2-2 will sweep primitives to
// consume `HLSurface` + `HLText`, and T2-5 will deprecate the legacy aliases.
//
// Hex values are operator-locked. No retune without his sign-off.

/// Tonal-Mono surface scale — warm-paper light, charcoal dark. Three-step
/// hierarchy mirrors `UIColor.systemBackground / .secondarySystemBackground /
/// .tertiarySystemBackground` but with brand-tuned hues so the entire app
/// reads as a single calm material.
///
/// **v0.14.11 light-theme redesign ("Warmes Papier"):** the light ramp moved
/// off pure white. Cards were `#FFFFFF`, which — under near-black text ink —
/// drove the operator verdict "Kontraste viel zu groß". Elevation on light is
/// now a *lightness ladder within the paper family*: recessed well below the
/// canvas, card a soft warm near-white above it, and pure `#FFFFFF` reserved
/// exclusively for the top elevation tier (`SurfaceElevated`). Steps are
/// deliberately subtle (≈1.07–1.18:1 between adjacent tiers) and paired with
/// the softened `HLShadow` — tonal steps + soft shadows, not borders.
///
/// **Light:** `#F2F0EB` (canvas) / `#FAF8F5` (cards) / `#E9E6E0` (recessed).
/// **Dark (unchanged):** `#101113` (canvas) / `#1A1B1F` (cards) / `#25262B` (recessed).
public enum HLSurface {
    /// Primary surface — full-screen canvas / app background.
    /// Warm paper in light, deep-charcoal in dark. **Never** pure white
    /// (clinical) or pure black (OLED-cold).
    public static let primary = Color("SurfacePrimary", bundle: .main)

    /// Secondary surface — card / tile backing.
    /// Warm near-white (`#FAF8F5`) in light — one soft tonal step above the
    /// paper canvas, never pure white; lifted-charcoal in dark for subtle
    /// card-vs-canvas separation.
    public static let secondary = Color("SurfaceSecondary", bundle: .main)

    /// Tertiary surface — recessed wells (chip backgrounds, inset rows,
    /// disabled states). Lighter than canvas in light, lighter than canvas
    /// in dark (counter-intuitively: dark mode wants lifted-not-darker for
    /// nested surfaces, per HIG §Materials).
    public static let tertiary = Color("SurfaceTertiary", bundle: .main)
}

/// Chrome accent namespace — **monochrome** as of v0.8.1.
///
/// Per the operator's monochrome direction ("chrome = monochrome, accent is
/// signal-only"), both `primary` and `userBrandTint` now resolve to the
/// monochrome `HLText.primary`. They no longer carry hue. v0.14 purple-sweep:
/// the `HLColor.purple` / `.pink` token literals were deleted — no surface
/// (LaunchScreen splash, OnboardingFlow hero, Coach brand-gradient, the
/// AccentColor asset) references them anymore; every former brand-anchor
/// already resolves through `HLText.primary` (mono graphite). Status/threshold
/// semantics keep their real signal colours (`StatusOK/Warn/Bad`).
/// Tinted-but-not-accent surfaces → `HLSurface.tertiary`.
public enum HLAccent {
    /// Chrome accent — monochrome, resolves to `HLText.primary`.
    ///
    /// **v0.8.1 monochrome-restore:** was `HLColor.purple` (`#BD93F9`).
    /// The v0.8.0 W6 sweep routed passive chrome (Settings rows, list-row
    /// chips, badges) here, which surfaced purple everywhere — the
    /// accent-picker UI was retired in v0.6.1.0 so the persisted tint was
    /// purple for essentially all users. Per the monochrome direction
    /// ("chrome = monochrome, accent is signal-only"), this now resolves to
    /// the monochrome `HLText.primary` (`#2E2B27` light / `#EBEBF5` dark).
    /// v0.14 purple-sweep: the `HLColor.purple` token literal was deleted —
    /// no brand-anchor surface references it anymore. Status/threshold
    /// semantics keep their real signal colours (`StatusOK/Warn/Bad`).
    public static var primary: Color {
        HLText.primary
    }

    /// Pressed / active-state variant — slightly dimmed for tactile feedback
    /// on tap. Used by `HLPressableButtonStyle` during the press transition.
    ///
    /// **v0.8.1/v0.8.2 monochrome-restore (W3a/A3):** was `HLColor.purpleDeep`,
    /// which flashed a stray purple on an otherwise monochrome button press.
    /// Re-pointed to a dimmed `HLText.primary` so the press state stays
    /// monochrome (chrome = mono, accent is signal-only). Kept subtle/brief.
    public static let pressed = HLText.primary.opacity(0.7)

    /// UX-H1 reconcile: the user-picked accent (`SettingsStore.preferredTint`)
    /// resolved at every read. Every non-brand-anchor accent surface routes
    /// here so the picker propagates instantly to: icon-tints, selection
    /// rings, `+ hinzufügen` affordances, retry CTAs, ShareLink action
    /// icons, tag-chip selection fills, and any other surface that should
    /// follow the user's pick.
    ///
    /// **v0.5.2-A8 reactivity caveat:** this is a `static var` that reads
    /// `UserDefaults` directly. SwiftUI's Observation tracking does not see
    /// the read as a dependency, so a view body that holds this value as a
    /// default-parameter or constant will NOT re-render when the
    /// `SettingsStore.preferredTint` mutates unless some OTHER tracked
    /// state on the same view changes. New code should prefer the
    /// SwiftUI-environment-driven path: `.foregroundStyle(.tint)` (reads
    /// the `.tint(...)` env value bound at the scene root) or
    /// `@Environment(SettingsStore.self)` directly so the picker propagates
    /// reactively to the surface. This accessor stays available as the
    /// non-View escape hatch (chart-tints, `HLChartTints.series` read at
    /// body re-eval time anyway).
    ///
    /// **v0.8.1 monochrome-restore:** previously read the persisted
    /// `hl.settings.tint` (default `.purple`). Since the accent-picker UI was
    /// retired in v0.6.1.0, that defaulted purple for everyone, so the v0.8.0
    /// W6 sweep routing chrome through this accessor turned the Settings hub,
    /// list-row icon chips, badges, the HealthScore neutral dial, and the
    /// achievement art purple. Re-pointed to the monochrome `HLText.primary`
    /// so all chrome renders neutral; the persisted key stays for backward
    /// compat but is no longer read for chrome.
    public static var userBrandTint: Color {
        HLText.primary
    }
}

/// Tonal-Mono text scale — one ink, three strengths.
///
/// **v0.14.11 light-theme redesign ("Warmes Papier"):** the light ramp is a
/// single warm ink `#2E2B27` at three opacities over the paper surfaces —
/// mirroring the dark ramp (`#EBEBF5` @ 1.0/0.7/0.4). The old light ramp was
/// broken at both ends: primary (`#1C1C1E@0.9` on pure white) screamed at
/// 12.6:1 while secondary (`#3C3C43@0.6`) *failed* WCAG AA at 3.4:1.
///
/// **Light (effective on card `#FAF8F5`):**
/// primary `#2E2B27 @ 0.90` → ≈9.8:1 (comfortable, still AAA);
/// secondary `@ 0.72` → ≈5.6:1 (now genuinely AA);
/// tertiary `@ 0.50` → ≈2.9:1 (decorative/disabled meta only).
/// **Dark (unchanged):** `#EBEBF5` @ 1.0 / 0.70 / 0.40.
///
/// The asset-catalog entries `TextPrimaryMono`, `TextSecondaryMono`,
/// `TextTertiaryMono` remain the single source; every call-site routes
/// through this namespace.
public enum HLText {
    /// Primary text — headings, body, primary metric values.
    public static let primary = Color("TextPrimaryMono", bundle: .main)

    /// Secondary text — captions, meta, units. ~70% of primary opacity.
    public static let secondary = Color("TextSecondaryMono", bundle: .main)

    /// Tertiary text — disabled, placeholder, decorative meta. ~40% opacity.
    public static let tertiary = Color("TextTertiaryMono", bundle: .main)
}
