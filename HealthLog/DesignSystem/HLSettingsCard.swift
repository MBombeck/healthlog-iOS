import SwiftUI

/// Settings sub-screen card primitive — **PB3 PA2 §Recommended Pattern,
/// W1-4 felt-UX shrink per R5 #2.**
///
/// Mirrors the web shell's `bg-card rounded-xl border p-6` cards used across
/// every `/settings/<slug>` page — proportionally trimmed for iPhone. On a
/// 393pt-wide iPhone the web's `p-6` (~20pt on iOS scale) reads as a chunky
/// box; we use 14pt internal padding so a two-row screen (e.g. Settings →
/// Konto) consumes noticeably less vertical real estate.
///
/// **Visual contract (post-W1-4):**
///
/// - **No per-card title icon** — R5 audit (#2 finding #3) showed the
///   18pt purple title icon repeated every ~120pt of scroll was the
///   surviving "bunt" feel after PB3 stripped rainbow row tints. The
///   accent now lives only on `HLSettingsRow` leading chips.
/// - `hlSubhead` (15pt) semibold title — aligns visually with the per-row
///   body font rather than a 20pt heading shouting at the user.
/// - Optional `hlCaption` subtitle in `textSecondary` directly below the
///   title row, single line (was 2 pre-W1-4).
/// - `Divider` at 60% opacity separating header block from body.
/// - 16pt internal spacing inside the body (matches web `space-y-4`).
/// - Canonical card radius (`HLRadius.card` = 20, W6-2) on an
///   `HLSurface.secondary` fill with a hairline `separator` border — the
///   Settings-tighter-10 split was retired so every card shares one radius.
/// - **14pt padding** (was 20pt pre-W1-4).
///
/// `icon:` is retained in the constructor signature for backward-
/// compatibility but unused — call-sites stay valid without churn.
///
/// **Why a new primitive over `HLCard`:**
/// `HLCard` is a content envelope (Dashboard tile, Achievement tile,
/// MeasureSheet card) that defines its own header in the caller. The
/// Settings rhythm needs the *title + subtitle + divider + body* shape
/// applied uniformly across the sub-screens — encoding it once here keeps
/// every Settings page visually identical to its web counterpart.
public struct HLSettingsCard<Content: View>: View {
    private let icon: String
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let bothSlotsJustification: StaticString?
    private let trailing: AnyView?
    private let content: Content
    /// v0.14.1 08-04 — same policy as `HLSettingsRow`: the header's layout and
    /// the subtitle's line cap are a function of the text size.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Standard constructor — icon + title + optional subtitle + body.
    ///
    /// **UI-Standard R5 / E9 — eine Karte belegt höchstens einen Beitext-Slot.**
    /// `subtitle` sagt, *was die Karte ist*; `footer` trägt *Folge oder
    /// Rechtliches*. Beide gleichzeitig zu setzen ist ein Verstoß, **außer** ein
    /// Review verlangt es auf einer Datenschutz-Fläche — dann muss der Grund als
    /// `bothSlotsJustification:` am Aufruf stehen (der Kommentar wandert damit
    /// aus dem Code-Kommentar in einen Parameter, den ein Werkzeug lesen kann).
    public init(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        bothSlotsJustification: StaticString? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.bothSlotsJustification = bothSlotsJustification
        trailing = nil
        self.content = content()
        warnOnDoubleSlot()
    }

    /// Trailing-slot constructor — for cards that need a status pill (or
    /// similar) anchored top-right in the title row (e.g. integrations
    /// cards with an `HLStatusPill`).
    public init(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        bothSlotsJustification: StaticString? = nil,
        @ViewBuilder trailing: () -> some View,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.bothSlotsJustification = bothSlotsJustification
        self.trailing = AnyView(trailing())
        self.content = content()
        warnOnDoubleSlot()
    }

    /// E9 — DEBUG-Warnung, wenn Subtitle **und** Footer belegt sind, ohne dass
    /// eine Begründung mitgeliefert wurde. Bewusst `HLLog` und **nicht**
    /// `assertionFailure`: die Alt-Fundstellen räumen U1–U7 auf, ein Crash
    /// würde die Testsuite bis dahin unbenutzbar machen. Die harte Erzwingung
    /// dieser Regel ist der statische Zähler `hl_card_both_slots` in
    /// `UIStandardBaselineTests` — dessen Baseline kann nur schrumpfen.
    private func warnOnDoubleSlot() {
        #if DEBUG
            guard subtitle != nil, footer != nil, bothSlotsJustification == nil else { return }
            HLLog.ui.debug("HLSettingsCard: subtitle + footer ohne bothSlotsJustification (UI-Standard R5)")
        #endif
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            header
            if let subtitle {
                // v0.6.1.5 Y5 — subtitle upgrades from `.hlCaption`
                // (12pt) to `.hlSubhead` (15pt) per handbook §1.3
                // hierarchy rule + AP-011 + operator's 'Lese-
                // /Schreibzugriff relativ klein' complaint on the
                // 2026-05-23 walkthrough. Caption-sized descriptions
                // routinely read smaller than the body text below
                // them, collapsing the title > description > caption
                // ordering. The new size sits above the card body's
                // own caption rows so the strict-monotonic step-down
                // holds.
                // 08-04: the one-line cap is a standard-size density decision.
                // A card header that truncates the sentence explaining what the
                // card is, precisely when the user has asked for larger text,
                // is the defect — not the density.
                Text(subtitle)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                content
            }
            if let footer {
                Text(footer)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, HLSpace.xs)
            }
        }
        .padding(HLSpace.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Theme-2.0 (T2-2): card fill → `HLSurface.secondary` so Settings
        // cards share the same card-on-canvas hue as Dashboard tiles. The
        // hairline border is retained at slightly lower opacity (0.6) so it
        // reads as a calm separator, not a chrome edge.
        .background(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .fill(HLSurface.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .stroke(HLColor.separator.opacity(0.6), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    /// The title row. At standard sizes it is the W1-4 shape unchanged; at an
    /// accessibility size the trailing status pill drops below the title instead
    /// of squeezing it, because a baseline-aligned pill next to a wrapped
    /// multi-line title has no baseline worth aligning to.
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                titleText
                if let trailing {
                    trailing
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                titleText
                Spacer(minLength: HLSpace.sm)
                if let trailing {
                    trailing
                }
            }
        }
    }

    // W1-4 — title icon dropped per R5 #2 finding #3.
    // `icon:` argument retained for ABI stability but unused.
    private var titleText: some View {
        Text(title)
            .font(.hlSubhead.weight(.semibold))
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - ScrollView wrapper

/// Wraps the standard `ScrollView { LazyVStack(spacing: HLSpace.xxl) { … } }`
/// shape every Settings sub-screen uses so callers don't repeat the boilerplate.
///
/// Use as the sole root view of a Settings sub-screen:
///
/// ```swift
/// HLSettingsPage(title: "Account") {
///     HLSettingsCard(icon: "person.crop.circle.fill", title: "Profile") { ... }
///     HLSettingsCard(icon: "key.fill", title: "Passkeys") { ... }
/// }
/// .navigationTitle("Account")
/// ```
///
/// **UI-Standard R5 / E1 — die Ebene „Seiten-Untertitel" existiert nicht mehr.**
/// Der frühere `subtitle:`-Parameter wurde seit W1-4 nicht mehr gerendert; 33
/// Aufrufstellen pflegten damit toten, teils falschen Text. Er ist ersatzlos
/// gelöscht — Orientierung gehört an die Hub-Zeile *vor* der Navigation (R3),
/// nicht auf die Zielseite, deren Titel ohnehin in der Navigationsleiste steht.
public struct HLSettingsPage<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    public init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            // W1-4 — drop the in-content `HLSettingsPageHeader` (hlTitle1
            // 28pt bold + subtitle). Every sub-screen calls
            // `.navigationTitle(...)` which already shows the title.
            LazyVStack(alignment: .leading, spacing: HLSpace.lg) {
                content
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.md)
            .padding(.bottom, HLSpace.xxxl)
        }
        // QoL-A2 (Glass H1) — the shared Settings scaffold now owns the
        // iOS-26 soft scroll-edge glass centrally, so all ~20 sub-screens
        // built on `HLSettingsPage` blur under the nav glass instead of
        // hard-clipping. Individual sub-screens must NOT re-apply
        // `.hlScrollEdgeSoft()` on their outer layer (it would land outside
        // this inner ScrollView and double-apply). No-op on iOS 18-25.
        .hlScrollEdgeSoft()
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
    }
}

#Preview("HLSettingsCard") {
    NavigationStack {
        HLSettingsPage(title: "Account") {
            HLSettingsCard(
                icon: "person.crop.circle.fill",
                title: "Profile",
                subtitle: "Dein Anzeigename und Stammdaten."
            ) {
                Text("Form fields would live here.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
            HLSettingsCard(
                icon: "key.fill",
                title: "Passkeys",
                footer: "Passkeys sind sicherer als Passwörter."
            ) {
                Text("Passkey list would live here.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}
