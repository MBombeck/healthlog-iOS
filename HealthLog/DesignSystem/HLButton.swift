import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

public struct HLButton: View {
    /// **UI-Standard R9 / E2.** Ziel sind drei Varianten mit klaren Anlässen:
    ///
    /// - `.primary` — höchstens **eine** pro Screen: die abschließende
    ///   Commit-Aktion eines Flows („Verbinden", „Import ausführen", „Speichern"
    ///   am Formularende).
    /// - `.secondary` — nachgeordnete Vollbreiten-Aktion neben einer `.primary`,
    ///   und der einheitliche Fehler-Retry („Erneut versuchen").
    /// - `.destructive` — destruktives Commit auf dem Bestätigungs-Screen.
    ///   Nie auf dem Screen, der nur dorthin führt.
    ///
    /// `.outline` ist in W0 gelöscht (Übersetzung laut R9 eins zu eins nach
    /// `.secondary`). `.ghost` und `.restrained` leben noch, weil ihre
    /// R9-Übersetzung **keine** mechanische ist: je nach Fundstelle wird daraus
    /// eine `HLSettingsActionRow` (wenn es eine Zeile in einer Karte war) oder
    /// `.secondary` (wenn es eine echte Vollbreiten-Aktion war). Diese
    /// Entscheidung trifft die Arbeitseinheit, die die Fläche besitzt (U1–U7);
    /// bis dahin hält der schrumpfende Zähler `hl_button_legacy_variant` in
    /// `UIStandardBaselineTests` den Bestand fest — er kann nur kleiner werden.
    public enum Variant {
        case primary
        case secondary
        case ghost
        case destructive
        /// v0.15.2 W-BUTTONS — restrained primary action. The operator
        /// flagged the full-`.tint`-fill `.primary` CTA as "too prominent /
        /// creepy" on in-card surfaces (Vorsorge "Jetzt messen", full-backup
        /// "Export erstellen", Settings saves). `.restrained` is the canonical
        /// twin of `ActiveMedicationRow.monochromeActionButton` — the
        /// "Genommen"/"Übersprungen" pair the operator likes: NO fill, a 1pt
        /// `HLText.tertiary` hairline, a monochrome `HLText.secondary` label,
        /// and the compact 44pt HIG height. It is a *primary* action that
        /// reads calm, not a big white slab. Use it for in-card / in-list
        /// commit actions; keep `.primary` for full-screen flow CTAs
        /// (onboarding) and `.destructive` for danger.
        case restrained
    }

    public enum Size {
        case regular
        case compact
        case large
    }

    /// Pure, test-visible description of the load-bearing restraint contract
    /// of the `.restrained` variant — so the W-BUTTONS regression (an
    /// accidental re-inflation back to a `.tint`-filled / oversized CTA) is
    /// locked without introspecting the SwiftUI body. Mirrors the
    /// `MedicationQuickMarkState.PresentationDescriptor` pattern used across
    /// the design-system snapshot suite.
    public struct RestrainedContract: Equatable, Sendable {
        /// The variant paints NO background fill (vs `.primary`'s `.tint` slab).
        public let hasFill: Bool
        /// The label ink is monochrome `HLText.secondary` — never an accent
        /// (B2: restrained CTAs must not carry accent).
        public let monochromeLabel: Bool
        /// Compact 44pt HIG floor regardless of any passed `size`.
        public let minHeight: CGFloat
    }

    /// The canonical restrained contract — the single source of truth the
    /// body's `background` / `textForegroundStyle` / `minHeight` honour for
    /// `.restrained`, and the value the W-BUTTONS test pins.
    public nonisolated static let restrainedContract = RestrainedContract(
        hasFill: false,
        monochromeLabel: true,
        minHeight: 44
    )

    private let title: String
    /// v0.14.1 W-I18N: whether `title` is a pre-rendered dynamic string that
    /// must be painted verbatim (medication/provider name, an interpolated
    /// count, any server value) rather than treated as a catalog key. The
    /// standard initializer localizes `title` via `LocalizedStringKey`; the
    /// `HLButton(verbatim:)` initializer sets this so already-resolved
    /// runtime text is never fed back through a second catalog lookup.
    private let isTitleVerbatim: Bool
    private let icon: String?
    private let variant: Variant
    private let size: Size
    private let isLoading: Bool
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    /// v0.6.0.5 REG-BTN clamp: the foreground / outline / hairline computations
    /// resolve the canvas surface per appearance so a `.weiss`-on-dark or
    /// `.schwarz`-on-light pick falls back to `HLText.primary` instead of
    /// collapsing into the canvas.
    @Environment(\.colorScheme) private var colorScheme

    /// v0.5.5.1 haptic migration: replaces the legacy
    /// `UIImpactFeedbackGenerator(style: .light).impactOccurred()` with
    /// iOS 17+'s declarative `.sensoryFeedback(.selection, trigger:)`.
    /// SwiftUI manages prepare-and-fire lifecycle internally + honours
    /// Reduce-Motion / per-app haptic settings, so the migration drops
    /// the UIKit dependency from the standard button tap.
    @State private var tapCount: Int = 0

    /// Standard initializer — `title` is treated as a **localization key**
    /// and resolved through the string catalog at render time via
    /// `LocalizedStringKey`. Pass a catalog id (`"allergies.add.title"`) or
    /// an English source literal (`"Save"`); both resolve to their catalog
    /// translation (or echo verbatim when no entry exists — non-breaking).
    /// For an already-resolved dynamic string, use `HLButton(verbatim:)`.
    public init(
        _ title: String,
        icon: String? = nil,
        variant: Variant,
        size: Size = .regular,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        isTitleVerbatim = false
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    /// Verbatim initializer — `title` is painted **as-is**, with no catalog
    /// lookup. Use for dynamic/user/server text that is already localized or
    /// carries runtime data (a medication or provider name, an interpolated
    /// count) so it is never re-resolved against the string catalog.
    public init(
        verbatim title: String,
        icon: String? = nil,
        variant: Variant,
        size: Size = .regular,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        isTitleVerbatim = true
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: triggerHaptic) {
            HStack(spacing: HLSpace.sm) {
                if isLoading {
                    // ProgressView's .tint(Color?) overload requires a
                    // concrete Color, not a ShapeStyle — for variants that
                    // wear white labels we pass white explicitly; for
                    // accent-coloured labels (.secondary) we
                    // omit `.tint` so the inherited `.tint(...)` from the
                    // parent environment paints the spinner.
                    if let spinnerTint {
                        ProgressView().controlSize(.small).tint(spinnerTint)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if let icon {
                    Image(systemName: icon)
                }
                titleText.font(font)
            }
            .frame(minHeight: minHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HLSpace.lg)
            .background(background)
            .foregroundStyle(textForegroundStyle)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            .overlay {
                // v0.6.0.5 REG-BTN: universal 1pt hairline keeps every
                // variant visually framed in both appearances, including
                // ghost / secondary on canvas where the fill is transparent.
                // R9: der Sonderfall mit eigener 1,5-pt-Kontur ist entfallen —
                // die Variante ging eins zu eins in `.secondary` auf.
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .strokeBorder(HLText.tertiary.opacity(0.25), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(isLoading ? 0.99 : 1)
            .hlAnimation(.easeOut(duration: 0.12), value: isLoading)
        }
        .buttonStyle(PressedScaleStyle())
        .sensoryFeedback(.selection, trigger: tapCount)
        .accessibilityLabel(titleText)
    }

    /// The label `Text` — localized through `LocalizedStringKey` for the
    /// standard initializer, or painted verbatim for `HLButton(verbatim:)`.
    /// Shared by the visible label and the accessibility label so both stay
    /// in lockstep. `LocalizedStringKey(runtimeString)` performs a catalog
    /// lookup, so a dotted key resolves to its translation and a plain
    /// literal echoes itself when it has no catalog entry.
    private var titleText: Text {
        isTitleVerbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title))
    }

    private func triggerHaptic() {
        guard !isLoading else { return }
        tapCount &+= 1
        action()
    }

    private var minHeight: CGFloat {
        // W-BUTTONS: `.restrained` always renders at the calm compact 44pt
        // HIG floor regardless of the passed `size`, so an accidental
        // `size: .large` can never re-inflate it back into the "creepy"
        // slab the operator flagged.
        if variant == .restrained { return 44 }
        switch size {
        case .compact: return 44 // HIG-Mindestmaß
        case .regular: return 48
        case .large: return 56
        }
    }

    private var font: Font {
        // W-BUTTONS: pin `.restrained` to `.hlSubhead` — the exact weight of
        // the `monochromeActionButton` label, and never larger than a section
        // heading (B1: typography must be ≤ heading).
        if variant == .restrained { return .hlSubhead }
        switch size {
        case .compact: return .hlSubhead
        case .regular: return .hlHeadline
        case .large: return .hlTitle3
        }
    }

    /// Primary CTAs paint a flat `.tint` fill; the scene-root `.tint` is the
    /// monochrome ink `HLText.primary`, so every `HLButton(.primary)` fills
    /// with the mono ink. Secondary reads transparent + outlined-on-press;
    /// destructive stays anchored to `HLColor.statusBad` because the danger
    /// semantic must not user-tune.
    private var background: AnyShapeStyle {
        switch variant {
        case .primary:
            AnyShapeStyle(.tint)
        case .secondary, .ghost, .restrained:
            AnyShapeStyle(Color.clear)
        case .destructive:
            AnyShapeStyle(HLColor.statusBad)
        }
    }

    /// Secondary buttons paint the monochrome ink `HLText.primary`
    /// as label color (no fill). The primary variant's fill is
    /// the mono ink too, so its foreground flips to `systemBackground` in dark
    /// mode (see `primaryForegroundColor`). Destructive stays anchored to
    /// `Color.white` because `HLColor.statusBad` is a fixed Dracula red.
    private var textForegroundStyle: AnyShapeStyle {
        switch variant {
        case .primary:
            AnyShapeStyle(primaryForegroundColor)
        case .destructive:
            AnyShapeStyle(Color.white)
        case .secondary:
            // v0.17 monochrome: secondary labels paint the mono ink
            // (`HLText.primary` never collapses against `HLSurface.primary`).
            AnyShapeStyle(HLText.primary)
        case .ghost:
            AnyShapeStyle(HLText.primary)
        case .restrained:
            // W-BUTTONS: monochrome label — NEVER the user's accent pick.
            // Mirrors `ActiveMedicationRow.monochromeActionButton`'s
            // `HLText.secondary` so the restrained CTA reads identically to
            // the "Genommen"/"Übersprungen" pair.
            AnyShapeStyle(HLText.secondary)
        }
    }

    /// Resolves the primary-variant foreground against the monochrome ink
    /// fill. The `.primary` background paints `AnyShapeStyle(.tint)`, and the
    /// scene-root `.tint` is `HLText.primary`. `Color.white` reads cleanly on
    /// the near-black light-mode ink but collapses on the near-white dark-mode
    /// ink, so the foreground flips to `systemBackground` (the ink's inverse)
    /// whenever white-on-ink sinks below the WCAG AA text ratio.
    private var primaryForegroundColor: Color {
        #if canImport(UIKit)
            let fillUI = UIColor(HLText.primary)
                .resolvedColor(with: UITraitCollection(
                    userInterfaceStyle: colorScheme == .dark ? .dark : .light
                ))
            let ratio = HLContrastClamp.contrastRatio(
                foreground: .white,
                background: fillUI
            )
            if ratio < HLContrastClamp.wcagAATextRatio {
                return Color(uiColor: .systemBackground)
            }
        #endif
        return Color.white
    }

    /// Concrete spinner tint for variants where we can't defer to the
    /// inherited `.tint(...)` — primary / destructive paint white labels
    /// so the spinner must read on the dark CTA fill; ghost reads as
    /// primary text. Returns nil when the inherited `.tint` is the right
    /// answer (secondary — accent on transparent). v0.5.2-R1:
    /// primary mirrors `primaryForegroundColor` so the spinner stays in
    /// the same colour as the label it's replacing.
    private var spinnerTint: Color? {
        switch variant {
        case .primary: primaryForegroundColor
        case .destructive: .white
        case .secondary: nil
        case .ghost: HLText.primary
        case .restrained: HLText.secondary
        }
    }
}

private struct PressedScaleStyle: ButtonStyle {
    // M3 (QOL-AUDIT): gate the press micro-shrink on Reduce Motion to match
    // `HLPressableButtonStyle.scale(for:)`. The haptic/opacity stay; only the
    // 0.97 scale jump is suppressed so the two canonical press primitives no
    // longer diverge.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .hlAnimation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("HLButton") {
    VStack(spacing: HLSpace.md) {
        HLButton("Primary", icon: "checkmark", variant: .primary) {}
        HLButton("Restrained", icon: "checkmark", variant: .restrained) {}
        HLButton("Secondary", variant: .secondary) {}
        HLButton("Ghost", variant: .ghost) {}
        HLButton("Destructive", icon: "trash", variant: .destructive) {}
        HLButton("Lade", variant: .primary, isLoading: true) {}
    }
    .padding()
    .background(HLSurface.primary)
}
