import SwiftUI

/// Canonical Settings row primitive — **B2 fix per M2-A3 §4.**
///
/// The previous `SettingsScreen` mixed five different row shapes (bare
/// `LabeledRow`, `Picker` without icon, `Toggle` without icon,
/// `NavigationLink` with tinted Label, `Button(role:.destructive)`) and
/// hit only 9/22 rows with leading icons. Apple-Settings hits ≈100 %, every
/// row sporting a 28×28 tinted rounded-square icon. This primitive enforces
/// that contract: every Settings row uses `HLSettingsRow` and contributes
/// its trailing accessory (chevron, Picker, Toggle, value text) via the
/// `trailing` `@ViewBuilder` slot.
///
/// **Why a separate primitive (vs reusing `HLListRow`):**
/// `HLListRow` was designed for measurement/medication list rows — it's a
/// standalone HStack inside `VStack { row; Divider; row }` content lists,
/// drawing its own row chrome. `HLSettingsRow` is designed for `List` / `Form`
/// rows: SwiftUI provides the row backing, separator, hit-area, etc., so the
/// primitive just paints the icon + label + trailing slot and leaves
/// chevron-on-`NavigationLink` to SwiftUI.
public struct HLSettingsRow<Trailing: View>: View {
    private let icon: String
    /// v0.5.2-A8 / v0.8.0-W6: `nil` means "use the live user accent"
    /// (`HLAccent.userBrandTint`, resolved at body-eval from
    /// `SettingsStore.preferredTint`). The prior `.accentColor` default read
    /// the *asset-catalog* AccentColor, not the live tint. A non-nil override
    /// paints a literal colour and is reserved for the rare brand-anchor row
    /// (still nowhere in production after the sweep, but kept as an escape
    /// hatch).
    private let iconTint: Color?
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let trailing: Trailing
    /// v0.14.1 08-04 — the row's layout is a function of the text size, not of
    /// the device. Read once here and spent in exactly two places: whether the
    /// hint may wrap, and whether the trailing accessory keeps its column.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        icon: String,
        iconTint: Color? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedLayout
            } else {
                compactLayout
            }
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
    }

    /// Standard sizes — byte-for-byte the W1-4 density: chip, labels, spacer,
    /// trailing, all on one line.
    private var compactLayout: some View {
        HStack(spacing: HLSpace.md) {
            HLSettingsIconChip(symbol: icon, tint: iconTint ?? HLAccent.userBrandTint)
            labels
            Spacer(minLength: HLSpace.sm)
            trailing
        }
    }

    /// Accessibility sizes — the trailing accessory stops competing for a width
    /// neither it nor the label can have and takes the line below. Nothing is
    /// hidden, scaled down or clipped; the row is simply allowed to be taller,
    /// which is the trade the user asked for when they enlarged the text.
    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .top, spacing: HLSpace.md) {
                HLSettingsIconChip(symbol: icon, tint: iconTint ?? HLAccent.userBrandTint)
                labels
                Spacer(minLength: 0)
            }
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            // W1-4: hub title shrinks from hlBody (17pt) to hlSubhead
            // (15pt) to align with Apple-Settings.app row density.
            Text(title)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            if let subtitle {
                // W1-4: the subtitle truncates after one line so a long hint
                // doesn't double the row height. 08-04: that density decision
                // was taken for standard sizes and never revisited — at an
                // accessibility size the row grew and said *less*, because a
                // single truncated line of very large text carries fewer words
                // than a single line of small text. The cap now applies only
                // where it was argued for. VoiceOver reads the full text either
                // way through the combined element on `body`.
                Text(subtitle)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
        }
    }
}

// MARK: - No-trailing convenience

public extension HLSettingsRow where Trailing == EmptyView {
    /// Convenience for rows whose trailing slot is empty (e.g. inside a
    /// `NavigationLink` where SwiftUI auto-paints the chevron, or for a
    /// pure-button row where the action lives on the row's outer tap).
    init(
        icon: String,
        iconTint: Color? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil
    ) {
        self.init(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

// MARK: - Value-text convenience

public extension HLSettingsRow where Trailing == HLSettingsRowValueText {
    /// Convenience for rows whose trailing slot is a single right-aligned
    /// value text — the most common shape for "Größe → 175 cm" type rows.
    init(
        icon: String,
        iconTint: Color? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: String
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            title: title,
            subtitle: subtitle
        ) {
            HLSettingsRowValueText(value: value)
        }
    }
}

/// Reusable trailing accessory for value-text Settings rows.
public struct HLSettingsRowValueText: View {
    let value: String
    public var body: some View {
        Text(value)
            .font(.hlBody)
            .foregroundStyle(HLText.secondary)
            .lineLimit(1)
    }
}

// MARK: - Action row

/// Canonical **tappable action row** — der Standard-Auslöser für jede Aktion
/// und jede Navigation innerhalb einer `HLSettingsCard` (UI-Standard R8/R10).
///
/// **FW1-C (H5):** ~22 Settings sub-screens hand-rolled the same shape —
/// a `Button` whose label is `HStack { Image(systemName:) at a raw 13/14/16pt
/// glyph; Text(...).font(.hlSubhead.weight(.semibold)); Spacer() }` — at
/// *drifting* glyph sizes and without the canonical tinted icon chip.
///
/// **UI-Standard W0 (E3) — was sich geändert hat:**
///
/// 1. `icon:` ist **optional**. Die 25 handgebauten Chevron-Zeilen des
///    Komponenten-Audits tragen keinen Chip; `icon: nil` bildet sie ab, ohne
///    dass jemand dafür wieder eine eigene Zeile baut.
/// 2. Das Trailing-Glyph wählt **nicht mehr der Aufrufer**, sondern der
///    Pflichtparameter `presents:`. Damit ist der Befund „vier optisch
///    identische Chevron-Zeilen, zwei davon öffnen ein Sheet"
///    (`SettingsDashboardScreen`) per Konstruktion unmöglich.
/// 3. `.push` kapselt den `NavigationLink`. Es ist über einen **eigenen**
///    Initializer erreichbar, der eine `destination:` verlangt — ein Chevron
///    ohne Push und ein Push ohne Chevron sind damit nicht mehr formulierbar,
///    und zwar zur Übersetzungszeit, nicht zur Laufzeit.
///
/// Die Zeile besitzt jetzt ihre Interaktion selbst (`NavigationLink` bzw.
/// `Button` inkl. `.buttonStyle(.plain)`). `.disabled(_:)`,
/// `.accessibilityIdentifier(_:)` und Präsentations-Modifier bleiben am
/// Aufrufer und wirken unverändert.
///
/// ```swift
/// // Push — das Primitive baut den NavigationLink:
/// HLSettingsActionRow(title: "Passkeys", presents: .push) { PasskeyManagementScreen() }
///
/// // Sheet / Erzeugen / Teilen / App verlassen / Bestätigen:
/// HLSettingsActionRow(icon: "plus", title: "Token erstellen", presents: .create) { … }
/// ```
public struct HLSettingsActionRow<Destination: View, Trailing: View>: View {
    /// Visual role — `.standard` tints chip + label with the user accent /
    /// primary text; `.destructive` routes both through `HLColor.statusBad`.
    public enum Role { case standard, destructive }

    /// R10 — das Versprechen der Zeile, und damit ihr Trailing-Glyph.
    ///
    /// `.push` fehlt hier **absichtlich**: ein Push ist ausschließlich über den
    /// `destination:`-Initializer erreichbar (siehe `Push`). Genau diese
    /// Trennung macht „Chevron, hinter dem ein Sheet aufgeht" unformulierbar.
    public enum Presents: String, Equatable, Sendable, CaseIterable {
        /// Bearbeiten-Transaktion in einem Sheet → `pencil`.
        case sheet
        /// Erzeugt etwas (Token, Link, Eintrag) in einem Sheet → `plus.circle`.
        case create
        /// Teilen-Blatt → `square.and.arrow.up`.
        case share
        /// Verlässt die App (Web-Seite, iOS-Einstellungen) → `arrow.up.right.square`.
        case external
        /// Löst direkt aus bzw. öffnet einen `confirmationDialog` — **kein**
        /// Glyph, weil die Zeile nirgendwohin führt.
        case confirm
    }

    /// Der einzige Fall des Push-Initializers. Existiert als eigener Typ, damit
    /// `presents:` auch an der Push-Zeile ein Pflichtparameter ist und am
    /// Aufruf sichtbar bleibt, was passiert.
    public enum Push: Equatable, Sendable { case push }

    private let icon: String?
    private let title: LocalizedStringKey
    private let role: Role
    /// When non-nil, overrides the label colour (used for the disabled/no-op
    /// affordance the Coach restore row needs without changing its behaviour).
    private let labelTintOverride: Color?
    /// `nil` ⇒ Push-Zeile (Chevron + `NavigationLink`).
    private let presents: Presents?
    private let destination: Destination?
    private let action: (() -> Void)?
    private let trailing: Trailing

    // MARK: - Push (NavigationLink)

    /// Push-Zeile: das Primitive baut den `NavigationLink` und paint den
    /// Chevron. Der Chevron ist hier nicht abwählbar — er *ist* die Aussage.
    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents _: Push,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.title = title
        self.role = role
        self.labelTintOverride = labelTintOverride
        presents = nil
        self.destination = destination()
        action = nil
        self.trailing = trailing()
    }

    // MARK: - Action (Button)

    /// Aktions-Zeile: Sheet, Erzeugen, Teilen, App verlassen oder Bestätigen.
    /// `presents:` legt das Trailing-Glyph fest; ein Chevron ist hier nicht
    /// erreichbar.
    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Presents,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) where Destination == EmptyView {
        self.icon = icon
        self.title = title
        self.role = role
        self.labelTintOverride = labelTintOverride
        self.presents = presents
        destination = nil
        self.action = action
        self.trailing = trailing()
    }

    private var chipTint: Color {
        role == .destructive ? HLColor.statusBad : HLAccent.userBrandTint
    }

    private var labelTint: Color {
        if let labelTintOverride { return labelTintOverride }
        return role == .destructive ? HLColor.statusBad : HLText.primary
    }

    /// R10 — das Glyph gehört dem Primitive, nicht dem Aufrufer. Reine,
    /// test-sichtbare Zuordnung (dasselbe Muster wie
    /// `HLButton.restrainedContract`), damit `HLSettingsActionRowContractTests`
    /// den Vertrag festnagelt, ohne den SwiftUI-Body zu inspizieren.
    /// `nil` heißt: kein Trailing-Glyph — die Zeile führt nirgendwohin.
    public nonisolated static func trailingSymbol(for presents: Presents) -> String? {
        switch presents {
        case .sheet: "pencil"
        case .create: "plus.circle"
        case .share: "square.and.arrow.up"
        case .external: "arrow.up.right.square"
        case .confirm: nil
        }
    }

    /// Push malt stattdessen den `HLDisclosureChevron` — siehe `label`.
    private var presentationSymbol: String? {
        presents.flatMap { Self.trailingSymbol(for: $0) }
    }

    private var label: some View {
        HStack(spacing: HLSpace.md) {
            if let icon {
                HLSettingsIconChip(symbol: icon, tint: chipTint)
            }
            Text(title)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(labelTint)
            Spacer(minLength: HLSpace.sm)
            trailing
            if presents == nil {
                HLDisclosureChevron()
            } else if let presentationSymbol {
                Image(systemName: presentationSymbol)
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(labelTintOverride ?? HLText.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    public var body: some View {
        if let destination {
            NavigationLink { destination } label: { label }
                .buttonStyle(.plain)
        } else if let action {
            Button(role: role == .destructive ? .destructive : nil, action: action) { label }
                .buttonStyle(.plain)
        }
    }
}

public extension HLSettingsActionRow where Trailing == EmptyView {
    /// Convenience — Push-Zeile ohne zusätzliches Trailing-Beiwerk.
    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Push,
        @ViewBuilder destination: () -> Destination
    ) {
        self.init(
            icon: icon,
            title: title,
            role: role,
            labelTintOverride: labelTintOverride,
            presents: presents,
            trailing: { EmptyView() },
            destination: destination
        )
    }

    /// Convenience — Aktions-Zeile ohne zusätzliches Trailing-Beiwerk.
    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Presents,
        action: @escaping () -> Void
    ) where Destination == EmptyView {
        self.init(
            icon: icon,
            title: title,
            role: role,
            labelTintOverride: labelTintOverride,
            presents: presents,
            trailing: { EmptyView() },
            action: action
        )
    }
}

// MARK: - Icon chip

/// 26×26 tinted rounded-square icon used as the leading accessory of every
/// `HLSettingsRow`. Public so other Settings-adjacent surfaces (e.g.
/// `AIProviderScreen`) can paint identical icon chips outside the row
/// envelope without re-implementing the geometry.
///
/// **W1-4:** shrunk from 28×28 / 15pt symbol to 26×26 / 13pt symbol per
/// R5 #2 audit — the 28pt chip felt visually large next to a 15pt
/// subhead title (the W1-4 row uses 15pt headings instead of 17pt body).
public struct HLSettingsIconChip: View {
    let symbol: String
    let tint: Color

    public init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
                .fill(tint.opacity(0.18))
            // Intentional fixed size:
            // Icon sits inside a fixed 26×26 chip — must scale with the chip,
            // not Dynamic Type. Chip dimension itself is a token decision.
            Image(systemName: symbol)
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

#Preview("HLSettingsRow") {
    // C-7 + Theme-2.0 (T2-2): preview reflects the single-brand-accent
    // contract — every passive Settings row uses `HLAccent.primary` as
    // its icon-chip tint (which is also the parameter's default). Per-row
    // colour drift is an anti-pattern in production code; the preview matches.
    Form {
        Section("Profile") {
            HLSettingsRow(
                icon: "person.crop.circle.fill",
                title: "Display name",
                value: "Anna"
            )
            HLSettingsRow(
                icon: "calendar",
                title: "Date of birth",
                value: "12.05.1980"
            )
        }
        // v0.14 purple-sweep: the prior "Accent color" picker preview row was
        // dead — the accent-picker UI was retired in v0.6.1.0 (chrome is mono),
        // and its `Picker(selection: "purple")` was the last purple literal in
        // a non-token file. Removed; the Personalization section now previews
        // the live appearance row only.
        Section("Personalization") {
            HLSettingsRow(
                icon: "moon.fill",
                title: "Erscheinungsbild"
            ) {
                Text("Dark")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }
}
