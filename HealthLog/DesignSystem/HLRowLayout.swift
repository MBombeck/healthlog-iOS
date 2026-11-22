import SwiftUI

/// What a row shows at its trailing edge to say what a tap does. The row draws
/// the glyph; a caller only names the promise.
public enum HLRowIndicator: Equatable, Sendable {
    /// Nothing happens on a tap, or the trailing control speaks for itself.
    case hidden
    /// The row pushes a page.
    case disclosure
    /// The row does something else and the symbol says what.
    case symbol(String)
    /// The row opens or closes content under it; the chevron turns down
    /// while it is open.
    case expand(Bool)

    /// The symbol of a row that leaves the app (Safari, the system settings,
    /// another app). Not to be mistaken for a trend arrow, which points
    /// straight up or down.
    public static let externalSymbol = "arrow.up.right"
}

/// The published measures of a row, for hosts that have to line up with it.
public enum HLRowMetrics {
    /// A row that takes a tap or holds a control is never lower than this.
    public static let minHeight: CGFloat = HLLayout.rowMinHeight
    /// Gap between the leading symbol, the text and the trailing slot.
    public static let gap: CGFloat = HLLayout.rowGap
    /// Vertical gap between a title and its subtitle.
    public static let labelSpacing: CGFloat = HLSpace.xxs
}

/// How one row family bends the shared grid. Screens reach the grid through
/// the public initialisers and cannot set any of this.
struct HLRowConfiguration {
    enum TitleStyle {
        /// The row's name: semibold.
        case title
        /// A sentence next to a symbol: regular weight, secondary ink.
        case statement
    }

    enum Stacking {
        /// The trailing control always stays on the title's line.
        case never
        /// The trailing slot moves under the title at accessibility sizes.
        case accessibilitySizes
        /// As above from XXL on, and below that whenever a title without a
        /// subtitle does not fit beside the trailing slot.
        case whenTight
    }

    enum TrailingFit {
        /// Text and trailing slot share the width (a value text may shorten).
        case shared
        /// The trailing slot keeps its own width (a pill, a switch).
        case intrinsic
    }

    var titleStyle: TitleStyle = .title
    var titleTint: Color = HLText.primary
    var indicatorTint: Color = HLText.tertiary
    var alignment: VerticalAlignment = .center
    var stacking: Stacking = .accessibilitySizes
    var trailingFit: TrailingFit = .shared
    var minHeight: CGFloat? = HLRowMetrics.minHeight
    /// A list row keeps to two lines on the left, title and one detail line,
    /// each cut at its end; only at the accessibility sizes do they wrap.
    /// Rows whose second line is an explanation (a switch's description, a
    /// sentence beside a symbol) wrap at every size.
    var limitsLines = true

    /// Symbol, title, value.
    static var standard: HLRowConfiguration {
        HLRowConfiguration()
    }

    /// A row that is itself the button.
    static func action(titleTint: Color, indicatorTint: Color) -> HLRowConfiguration {
        HLRowConfiguration(
            titleTint: titleTint,
            indicatorTint: indicatorTint,
            stacking: .whenTight,
            trailingFit: .intrinsic
        )
    }

    /// A row that ends in a switch.
    static var toggle: HLRowConfiguration {
        HLRowConfiguration(stacking: .never, trailingFit: .intrinsic, limitsLines: false)
    }

    /// Label and figure of a table of facts. Not a control, so it keeps the
    /// height of its text.
    static var stat: HLRowConfiguration {
        HLRowConfiguration(alignment: .firstTextBaseline, minHeight: nil)
    }

    /// A sentence beside a symbol. Not a control, so it keeps the height of
    /// its text.
    static var statement: HLRowConfiguration {
        HLRowConfiguration(
            titleStyle: .statement,
            titleTint: HLText.secondary,
            alignment: .top,
            stacking: .never,
            trailingFit: .intrinsic,
            minHeight: nil,
            limitsLines: false
        )
    }
}

/// The shared grid of every row: leading symbol, title with optional subtitle,
/// trailing slot, indicator.
///
/// The row families (`HLSettingsRow`, `HLSettingsActionRow`,
/// `HLSettingsToggleRow`, `HLSettingsStatRow`, `HLIconTextRow`, `HLListRow`)
/// are built on it. A row with domain content of its own uses it directly for
/// the grid and puts its content into the slots.
public struct HLRowLayout<Leading: View, Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let indicator: HLRowIndicator
    private let configuration: HLRowConfiguration
    private let leading: Leading
    private let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A row with a value at its right edge and a symbol at its left.
    ///
    /// The value comes first, so the unnamed closure after the call is
    /// always the right-hand side of the row:
    /// `HLRowLayout(title: "Pulse") { value } leading: { symbol }`.
    public init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        indicator: HLRowIndicator = .hidden,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            indicator: indicator,
            configuration: .standard,
            leading: leading,
            trailing: trailing
        )
    }

    /// For titles that exist only at run time (a name the user typed).
    public init(
        title: Text,
        subtitle: Text? = nil,
        indicator: HLRowIndicator = .hidden,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            indicator: indicator,
            configuration: .standard,
            leading: leading,
            trailing: trailing
        )
    }

    init(
        title: Text,
        subtitle: Text?,
        indicator: HLRowIndicator,
        configuration: HLRowConfiguration,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.indicator = indicator
        self.configuration = configuration
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        arranged
            .frame(maxWidth: .infinity, minHeight: configuration.minHeight, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var arranged: some View {
        switch configuration.stacking {
        case .never:
            sideBySide(titleOnOneLine: false)
        case .accessibilitySizes:
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                sideBySide(titleOnOneLine: false)
            }
        case .whenTight:
            if dynamicTypeSize >= .xxLarge {
                stacked
            } else if subtitle == nil {
                // A short name beside a pill stays on one line; a long one
                // gives the pill its own line instead of breaking into
                // syllables.
                ViewThatFits(in: .horizontal) {
                    sideBySide(titleOnOneLine: true)
                    stacked
                }
            } else {
                sideBySide(titleOnOneLine: false)
            }
        }
    }

    private func sideBySide(titleOnOneLine: Bool) -> some View {
        HStack(alignment: configuration.alignment, spacing: HLRowMetrics.gap) {
            leading
            switch configuration.trailingFit {
            case .shared:
                labels
                Spacer(minLength: HLSpace.sm)
                trailing
            case .intrinsic:
                labels
                    .fixedSize(horizontal: titleOnOneLine, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                trailing
                    .fixedSize()
            }
            indicatorGlyph
        }
    }

    /// The trailing slot takes the full width under the text, so nothing is
    /// cut or scaled down when the text is large. At the accessibility sizes
    /// the symbol stands above the title as well: beside it, it takes a
    /// quarter of the line and a word like "Laborwerte" breaks in two.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            // The indicator stands at the middle of a two-line title like it
            // does beside a one-line title. Where the symbol stands above the
            // title (accessibility sizes) it keeps to the title's first line,
            // so it neither floats beside the symbol nor drops to the middle
            // of a long name.
            HStack(alignment: HLRowLayoutAlignment.indicator(at: dynamicTypeSize), spacing: HLRowMetrics.gap) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        leading
                        labels
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    leading
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                indicatorGlyph
            }
            trailing
        }
    }

    private var labels: some View {
        let halfCapHeight = HLRowLayoutAlignment.titleCapHeight(at: dynamicTypeSize) / 2
        return VStack(alignment: .leading, spacing: HLRowMetrics.labelSpacing) {
            title
                .font(titleFont)
                .foregroundStyle(configuration.titleTint)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.hlRowFirstLine) { dimensions in
                    dimensions[.firstTextBaseline] - halfCapHeight
                }
            if let subtitle {
                subtitle
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(subtitleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lineLimit: Int? {
        HLRowLineLimits.title(limitsLines: configuration.limitsLines, dynamicTypeSize: dynamicTypeSize)
    }

    private var subtitleLineLimit: Int? {
        HLRowLineLimits.subtitle(limitsLines: configuration.limitsLines, dynamicTypeSize: dynamicTypeSize)
    }

    private var titleFont: Font {
        switch configuration.titleStyle {
        case .title: HLRowTitle.font
        case .statement: .hlSubhead
        }
    }

    @ViewBuilder
    private var indicatorGlyph: some View {
        switch indicator {
        case .hidden:
            EmptyView()
        case .disclosure:
            HLDisclosureChevron()
        case let .expand(expanded):
            HLDisclosureChevron(expanded: expanded)
        case let .symbol(name):
            Image(systemName: name)
                .font(.hlFootnote.weight(.semibold))
                .dynamicTypeSize(...HLDisclosureChevron.largestTypeSize)
                .foregroundStyle(configuration.indicatorTint)
                .accessibilityHidden(true)
        }
    }
}

/// Where the trailing indicator of a row lines up with the text beside it.
enum HLRowLayoutAlignment {
    /// The middle of the row beside a title of any length; the middle of
    /// the title's first line where the symbol stands above the title.
    static func indicator(at typeSize: DynamicTypeSize) -> VerticalAlignment {
        typeSize.isAccessibilitySize ? .hlRowFirstLine : .center
    }

    /// Half of it above the first baseline is the optical middle of the
    /// title's first line.
    @MainActor
    static func titleCapHeight(at typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).capHeight
    }
}

extension VerticalAlignment {
    private enum HLRowFirstLine: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    /// The middle of a row title's first line; anything else aligns on its
    /// own middle.
    static let hlRowFirstLine = VerticalAlignment(HLRowFirstLine.self)
}

/// The title of a row on its own, for the rows the system draws.
///
/// Every row title is the same text: subhead, semibold, primary colour. A
/// picker or a date picker in a form takes it as its label, so its title
/// reads like the titles of the rows around it:
/// `DatePicker(selection: $date) { HLRowTitle("Date") }`.
public struct HLRowTitle: View {
    /// Font of every row title.
    public static let font: Font = .hlSubhead.weight(.semibold)

    private let title: Text

    public init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    /// For titles that exist only at run time.
    public init(_ title: Text) {
        self.title = title
    }

    public var body: some View {
        title
            .font(Self.font)
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public extension HLRowLayout where Leading == EmptyView {
    /// A row with a value at its right edge and no symbol.
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        indicator: HLRowIndicator = .hidden,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, subtitle: subtitle, indicator: indicator, trailing: trailing, leading: { EmptyView() })
    }

    /// For titles that exist only at run time (a name the user typed).
    init(
        title: Text,
        subtitle: Text? = nil,
        indicator: HLRowIndicator = .hidden,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(title: title, subtitle: subtitle, indicator: indicator, trailing: trailing, leading: { EmptyView() })
    }
}

public extension HLRowLayout where Leading == EmptyView, Trailing == EmptyView {
    /// A row of text alone, with its indicator.
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        indicator: HLRowIndicator = .hidden
    ) {
        self.init(title: title, subtitle: subtitle, indicator: indicator, trailing: { EmptyView() })
    }

    /// For titles that exist only at run time (a name the user typed).
    init(
        title: Text,
        subtitle: Text? = nil,
        indicator: HLRowIndicator = .hidden
    ) {
        self.init(title: title, subtitle: subtitle, indicator: indicator, trailing: { EmptyView() })
    }
}

#Preview("HLRowLayout, light") {
    HLRowLayoutPreview()
        .preferredColorScheme(.light)
}

#Preview("HLRowLayout, dark") {
    HLRowLayoutPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLRowLayout, largest type") {
    HLRowLayoutPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLRowLayoutPreview: View {
    var body: some View {
        HLPage {
            HLCard("Overview", layout: .rows) {
                HLRowLayout(title: "Blood pressure", indicator: .disclosure) {
                    HLValueText(128, 82, unit: .millimetersOfMercury)
                } leading: {
                    HLSettingsIconChip(symbol: "heart.fill", tint: HLAccent.userBrandTint)
                }
                HLRowLayout(title: "Weight", subtitle: "No entries yet") {
                    EmptyView()
                } leading: {
                    HLSettingsIconChip(symbol: "scalemass.fill", tint: HLAccent.userBrandTint)
                }
                HLRowLayout(title: Text(verbatim: "Lisinopril 5 mg"), indicator: .symbol("pencil"))
            }
        }
    }
}

/// Line limits of a row's labels. The title keeps one line so rows line up;
/// the detail may take a second line, because a cut hint ("Für Medikamenten-
/// und Stimmungs-Erinn…") hides what the row is for. At the accessibility
/// sizes nothing is cut.
public enum HLRowLineLimits {
    public static func title(limitsLines: Bool, dynamicTypeSize: DynamicTypeSize) -> Int? {
        limitsLines && !dynamicTypeSize.isAccessibilitySize ? 1 : nil
    }

    public static func subtitle(limitsLines: Bool, dynamicTypeSize: DynamicTypeSize) -> Int? {
        limitsLines && !dynamicTypeSize.isAccessibilitySize ? 2 : nil
    }
}
