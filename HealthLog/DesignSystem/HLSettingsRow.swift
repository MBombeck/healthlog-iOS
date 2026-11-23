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
    /// `nil` means "use the live user accent"
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
        HLRowLayout(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            indicator: .hidden,
            configuration: .standard,
            leading: { HLSettingsIconChip(symbol: icon, tint: iconTint ?? HLAccent.userBrandTint) },
            trailing: { trailing }
        )
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
        // As large as the row title, one weight lighter: the value never
        // outweighs the name it belongs to.
        Text(value)
            .font(HLRowValue.Emphasis.setting.font)
            .foregroundStyle(HLRowValue.Emphasis.setting.tint)
            .lineLimit(1)
    }
}

// MARK: - Action row

/// Canonical **tappable action row** — der Standard-Auslöser für jede Aktion
/// und jede Navigation innerhalb einer `HLCard` (UI-Standard R8/R10).
///
/// ~22 Settings sub-screens hand-rolled the same shape —
/// a `Button` whose label is `HStack { Image(systemName:) at a raw 13/14/16pt
/// glyph; Text(...).font(.hlSubhead.weight(.semibold)); Spacer() }` — at
/// *drifting* glyph sizes and without the canonical tinted icon chip.
///
/// **UI-Standard W0 — was sich geändert hat:**
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
/// HLSettingsActionRow(title: "Token erstellen", presents: .create) { … }
/// ```
public struct HLSettingsActionRow<Destination: View, Trailing: View>: View {
    /// Visual role — `.standard` tints chip + label with the user accent /
    /// primary text; `.destructive` routes both through `HLColor.statusBad`.
    public enum Role { case standard, destructive }

    /// Das Versprechen der Zeile, und damit ihr Zubehör.
    ///
    /// Rechts stehen nur die Zeichen, die iOS kennt: der Chevron für alles,
    /// was eine Seite oder ein Sheet öffnet, `arrow.up.right` für ein Ziel
    /// außerhalb der App, das Teilen-Zeichen für das Teilen-Blatt. Etwas
    /// Neues anlegen trägt das Plus vorn im Symbolfeld, wie „Erinnerung
    /// anlegen“, und rechts nichts.
    public enum Presents: String, Equatable, Sendable, CaseIterable {
        /// Öffnet ein Sheet zum Bearbeiten → Chevron.
        case sheet
        /// Erzeugt etwas (Token, Link, Eintrag) in einem Sheet → vorn das
        /// Plus, rechts nichts.
        case create
        /// Teilen-Blatt → `square.and.arrow.up`.
        case share
        /// Verlässt die App (Web-Seite, iOS-Einstellungen) → `arrow.up.right`.
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
    /// One line under the label. It carries what a card's subtitle
    /// said when the card had only this row and lost its own title.
    private let subtitle: LocalizedStringKey?
    private let role: Role
    /// When non-nil, overrides the label colour (used for the disabled/no-op
    /// affordance the Coach restore row needs without changing its behaviour).
    private let labelTintOverride: Color?
    /// `nil` ⇒ Push-Zeile (Chevron + `NavigationLink`).
    private let presents: Presents?
    private let destination: Destination?
    /// A push by value (`NavigationLink(value:)`), see the value init.
    private let valueLink: ((AnyView) -> NavigationLink<AnyView, Never>)?
    private let action: (() -> Void)?
    private let trailing: Trailing

    // MARK: - Push (NavigationLink)

    /// Push-Zeile: das Primitive baut den `NavigationLink` und paint den
    /// Chevron. Der Chevron ist hier nicht abwählbar — er *ist* die Aussage.
    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents _: Push,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.labelTintOverride = labelTintOverride
        presents = nil
        self.destination = destination()
        valueLink = nil
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
        subtitle: LocalizedStringKey? = nil,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Presents,
        @ViewBuilder trailing: () -> Trailing,
        action: @escaping () -> Void
    ) where Destination == EmptyView {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.labelTintOverride = labelTintOverride
        self.presents = presents
        destination = nil
        valueLink = nil
        self.action = action
        self.trailing = trailing()
    }

    /// Push-Zeile per Wert: appends `value` to the
    /// enclosing stack's path, so the page survives the privacy shield
    /// rebuilding the window. A `navigationDestination(for:)` of the stack
    /// resolves it; same chevron as the destination init.
    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        presents _: Push,
        value: some Hashable
    ) where Destination == EmptyView, Trailing == EmptyView {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        role = .standard
        labelTintOverride = nil
        presents = nil
        destination = nil
        valueLink = { label in NavigationLink(value: value) { label } }
        action = nil
        trailing = EmptyView()
    }

    /// Push-Zeile per Wert mit Trailing: the same as above
    /// with a state pill beside the chevron, for the provider rows of
    /// Integrations.
    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        presents _: Push,
        value: some Hashable,
        @ViewBuilder trailing: () -> Trailing
    ) where Destination == EmptyView {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        role = .standard
        labelTintOverride = nil
        presents = nil
        destination = nil
        valueLink = { label in NavigationLink(value: value) { label } }
        action = nil
        self.trailing = trailing()
    }

    private var chipTint: Color {
        role == .destructive ? HLColor.statusBad : HLAccent.userBrandTint
    }

    private var labelTint: Color {
        if let labelTintOverride { return labelTintOverride }
        return role == .destructive ? HLColor.statusBad : HLText.primary
    }

    /// Das Zubehör gehört dem Primitive, nicht dem Aufrufer. Reine,
    /// test-sichtbare Zuordnung, damit `HLSettingsActionRowContractTests`
    /// den Vertrag festnagelt, ohne den SwiftUI-Body zu inspizieren.
    public nonisolated static func indicator(for presents: Presents) -> HLRowIndicator {
        switch presents {
        case .sheet: .disclosure
        case .share: .symbol("square.and.arrow.up")
        case .external: .symbol(HLRowIndicator.externalSymbol)
        case .create, .confirm: .hidden
        }
    }

    /// Das Zeichen rechts, wo es kein Chevron ist: `nil` für den Chevron
    /// und für eine Zeile ohne Zubehör.
    public nonisolated static func trailingSymbol(for presents: Presents) -> String? {
        if case let .symbol(name) = indicator(for: presents) { return name }
        return nil
    }

    /// Das Symbol im Symbolfeld vorn: das des Aufrufers, sonst bei einer
    /// Zeile, die etwas anlegt, das Plus.
    public nonisolated static func leadingSymbol(icon: String?, presents: Presents?) -> String? {
        if let icon { return icon }
        return presents == .create ? createSymbol : nil
    }

    /// The sign in front of a row that creates something.
    public nonisolated static var createSymbol: String {
        "plus"
    }

    /// Whether a row with this promise is a link for VoiceOver. A row that
    /// leaves the app opens a page elsewhere, and "link" is the word that
    /// says so; every other row stays a button.
    public nonisolated static func isLink(_ presents: Presents) -> Bool {
        presents == .external
    }

    private var opensLink: Bool {
        presents.map(Self.isLink) ?? false
    }

    /// A push and a sheet show the chevron, sharing and leaving the app
    /// their own symbol, creating and confirming nothing.
    private var indicator: HLRowIndicator {
        guard let presents else { return .disclosure }
        return Self.indicator(for: presents)
    }

    /// The trailing accessory (a status pill) keeps its own width, so
    /// "Verbunden" never breaks into syllables; where name and pill no longer
    /// share a line, the pill moves under the name.
    private var label: some View {
        HLRowLayout(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            indicator: indicator,
            configuration: .action(titleTint: labelTint, indicatorTint: labelTintOverride ?? HLText.tertiary),
            leading: {
                if let symbol = Self.leadingSymbol(icon: icon, presents: presents) {
                    HLSettingsIconChip(symbol: symbol, tint: chipTint)
                }
            },
            trailing: { trailing }
        )
    }

    public var body: some View {
        // The row draws its own chevron; in a Form or List the system added
        // a second one beside it (cycle settings, Apple Health row).
        if let destination {
            NavigationLink { destination } label: { label }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
        } else if let valueLink {
            valueLink(AnyView(label))
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
        } else if let action {
            Button(role: role == .destructive ? .destructive : nil, action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(opensLink ? .isLink : [])
                .accessibilityRemoveTraits(opensLink ? .isButton : [])
        }
    }
}

#Preview("HLSettingsRow") {
    // C-7 + Theme-2.0: preview reflects the single-brand-accent
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
