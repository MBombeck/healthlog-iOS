import SwiftUI

/// A status under a row value: symbol and text, without a capsule.
///
/// It is the only status a list row carries. A capsule belongs to a card
/// head or a detail head (``HLBadge``).
public struct HLRowStatus: Equatable, Sendable {
    let title: String
    let icon: String?
    let tone: HLBadge.Tone

    public init(_ title: String, icon: String? = nil, tone: HLBadge.Tone = .neutral) {
        self.title = title
        self.icon = icon
        self.tone = tone
    }

    @MainActor
    var badge: HLBadge {
        HLBadge(title, icon: icon, tone: tone, form: .text)
    }
}

/// The one control or indicator at the right edge of a row. A row carries
/// at most one, so the type holds exactly one.
///
/// A data row (a value, an entry, an object) carries none: the whole row is
/// the tap target (``HLRowButton`` or a `NavigationLink` with
/// `.buttonStyle(.hlRow)`). The chevron is for menu rows only, which lead
/// to a settings page or a picker and show no value of their own.
public enum HLRowAccessory {
    /// Nothing; the default for every data row.
    case none
    /// A menu row that opens a page or a picker. Chosen on purpose, never
    /// on a row that shows a value, an entry or an object.
    case chevron
    /// The row leaves the app: `arrow.up.right`, in the chevron's place and
    /// size, never beside a chevron.
    case external
    /// The row opens or closes content under it; the chevron turns while
    /// it is open.
    case expand(Bool)
    /// The row is the label of a `Menu`: the menu symbol. The caller wraps
    /// the row in the menu.
    case menu
    /// The row does something else and the symbol says what.
    case symbol(String)
    /// A switch. A row with a switch shows no value.
    case toggle(Binding<Bool>)

    var indicator: HLRowIndicator {
        switch self {
        case .none, .toggle: .hidden
        case .chevron: .disclosure
        case .external: .symbol(HLRowIndicator.externalSymbol)
        case let .expand(expanded): .expand(expanded)
        case .menu: .symbol("ellipsis")
        case let .symbol(name): .symbol(name)
        }
    }
}

/// The detail line of a row from several side facts (date, count, source,
/// type), joined by ", ".
public enum HLRowDetail {
    /// Empty and missing parts drop out; with none left there is no line.
    public static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: ", ")
    }

    /// The joined line as a text for ``HLRow``'s `detail`.
    public static func text(_ parts: [String?]) -> Text? {
        joined(parts).map { Text(verbatim: $0) }
    }
}

/// The one list row of the app: documents, lab results, nutrients,
/// readings, visits, sessions, devices, settings.
///
/// - Left: an optional symbol in the 26 pt column (``HLRowGlyph`` or
///   ``HLSettingsIconChip``).
/// - Beside it at most two lines: the title (15 pt semibold) and one detail
///   line (12 pt secondary). Several side facts share the detail line,
///   joined by ``HLRowDetail``. Each line is cut at its end.
/// - Right: the value (15 pt medium, digits of equal width) with at most
///   one status line under it, and at most one accessory. A data row has
///   none; the chevron is for menu rows.
///
/// At the accessibility sizes title and detail wrap, and the right side
/// moves under the left.
public struct HLRow<Leading: View>: View {
    private let title: Text
    private let detail: Text?
    private let value: Text?
    private let status: HLRowStatus?
    private let accessory: HLRowAccessory
    private let leading: Leading
    /// A drill row's count is a fact, not a reading; only the building
    /// blocks set it.
    var valueEmphasis: HLRowValue.Emphasis = .reading

    /// A row whose title exists only at run time.
    public init(
        title: Text,
        detail: Text? = nil,
        value: Text? = nil,
        status: HLRowStatus? = nil,
        accessory: HLRowAccessory = .none,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.detail = detail
        self.value = value
        self.status = status
        self.accessory = accessory
        self.leading = leading()
    }

    /// A row with a title from the catalogue.
    public init(
        _ title: LocalizedStringKey,
        detail: Text? = nil,
        value: Text? = nil,
        status: HLRowStatus? = nil,
        accessory: HLRowAccessory = .none,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: Text(title),
            detail: detail,
            value: value,
            status: status,
            accessory: accessory,
            leading: leading
        )
    }

    public var body: some View {
        HLRowLayout(
            title: title,
            subtitle: detail,
            indicator: accessory.indicator,
            configuration: configuration,
            leading: { leading },
            trailing: { trailing }
        )
    }

    @ViewBuilder
    private var trailing: some View {
        if case let .toggle(isOn) = accessory {
            // The app's switch style draws any label it is given, so the
            // switch carries none; the row's title names it for VoiceOver.
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
        } else if value != nil || status != nil {
            HLRowValue(value: value, emphasis: valueEmphasis, status: status)
        }
    }

    private var configuration: HLRowConfiguration {
        if case .toggle = accessory {
            // The switch keeps its own width; the text gives way to it.
            return HLRowConfiguration(trailingFit: .intrinsic)
        }
        return .standard
    }
}

public extension HLRow where Leading == EmptyView {
    /// A row without a symbol, title only at run time.
    init(
        title: Text,
        detail: Text? = nil,
        value: Text? = nil,
        status: HLRowStatus? = nil,
        accessory: HLRowAccessory = .none
    ) {
        self.init(title: title, detail: detail, value: value, status: status, accessory: accessory) {
            EmptyView()
        }
    }

    /// A row without a symbol, title from the catalogue.
    init(
        _ title: LocalizedStringKey,
        detail: Text? = nil,
        value: Text? = nil,
        status: HLRowStatus? = nil,
        accessory: HLRowAccessory = .none
    ) {
        self.init(title: Text(title), detail: detail, value: value, status: status, accessory: accessory) {
            EmptyView()
        }
    }
}

/// A data row as one button: the whole row takes the tap, gives the press
/// feedback of every tappable surface and is a button for VoiceOver. No
/// chevron is needed to say that it opens something.
public struct HLRowButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
    }
}

public extension ButtonStyle where Self == HLPressableButtonStyle {
    /// Press feedback for a data row that is a `Button` or a
    /// `NavigationLink` as a whole.
    @MainActor
    static var hlRow: HLPressableButtonStyle {
        HLPressableButtonStyle(hover: .highlight)
    }
}

#Preview("HLRow") {
    HLPage {
        HLCard(layout: .rows) {
            HLRow(
                title: Text(verbatim: "Befund Hausarzt"),
                detail: HLRowDetail.text(["12.11.2026", "PDF", "240 KB"]),
                accessory: .chevron
            ) {
                HLRowGlyph(symbol: "doc.text")
            }
            HLRow(
                title: Text(verbatim: "INR"),
                detail: Text(verbatim: "2 Werte, zuletzt 03.11."),
                value: Text(verbatim: "1,3"),
                status: HLRowStatus("Über Bereich", icon: "arrow.up", tone: .warning)
            )
            HLRow(title: Text(verbatim: "Erinnerungen"), accessory: .toggle(.constant(true)))
        }
    }
}
