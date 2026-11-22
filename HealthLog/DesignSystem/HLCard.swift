import SwiftUI

/// How a card draws itself. Callers choose between the filled card and the
/// outlined one; inset, radius, surface, hairline and shadow are not theirs
/// to set.
public enum HLCardStyle: Equatable, Sendable {
    /// Filled content card.
    case standard
    /// Transparent card with a hairline outline.
    case outline

    /// Former name of the filled card with a stronger shadow. Draws as
    /// ``standard``; use that instead.
    public static var elevated: HLCardStyle {
        .standard
    }

    /// Former name of ``outline``; use that instead.
    public static var ghost: HLCardStyle {
        .outline
    }
}

/// The surface behind every content card.
///
/// Content cards are opaque: Liquid Glass belongs to the control layer above
/// the content (bars, floating controls, icon buttons in a tab header), and an
/// opaque fill gives every card the same grey in the dark appearance.
public enum HLCardSurface: Equatable, Sendable {
    /// The only surface a content card has. The glass card is gone for
    /// good: glass on content breaks Apple's rule that glass floats above it.
    case opaque

    /// The surface of all content cards.
    public static let content: HLCardSurface = .opaque

    /// Width of the hairline around a filled card.
    public static let hairlineWidth: CGFloat = 0.5
    /// Width of the outline of an ``HLCardStyle/outline`` card.
    public static let outlineWidth: CGFloat = 1
}

/// How a card pads its content. The mode stands at the call; the card does
/// not guess it from its title or from what it is given.
public enum HLCardLayout: Equatable, Sendable {
    /// Free content (a text block, a row of facts, a chart, a tile): the card
    /// inset on every side. The default, with and without a title.
    case free
    /// Rows: half a row spacing above the first and below the last row, so
    /// the rows of a card stand on the same grid as the rows of a list.
    ///
    /// Right only where the first and the last element are full rows of the
    /// row height: their text then stands a card inset from the edge. A card
    /// that begins or ends with running text stays ``free``.
    case rows
}

/// The one content card.
///
/// Without a title it is an envelope around its content. With a title it
/// carries a head above it: title, optional subtitle, divider. The head is the
/// same in both layouts; the ``HLCardLayout`` at the call says how the content
/// under it is padded.
///
/// A card carries at most one line of side text: `subtitle` says what the
/// card is, `footer` carries a consequence or a legal note. Where a review
/// asks for both, the reason stands at the call as `bothSlotsJustification:`.
public struct HLCard<Trailing: View, Content: View>: View {
    public typealias Style = HLCardStyle
    public typealias Layout = HLCardLayout

    private let title: Text?
    /// Rubric (``HLTextRole/cardTitle``) or thing (``HLTextRole/objectName``).
    private let titleRole: HLTextRole
    private let subtitle: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let bothSlotsJustification: StaticString?
    private let style: Style
    private let layout: Layout
    private let trailing: Trailing
    private let content: Content
    /// The header's layout is a function of the text size.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A card whose title row carries a trailing element (a status pill, a
    /// count) at its right edge.
    public init(
        _ title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        bothSlotsJustification: StaticString? = nil,
        style: Style = .standard,
        layout: Layout = .free,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            heading: title.map { Text($0) },
            role: .cardTitle,
            subtitle: subtitle,
            footer: footer,
            bothSlotsJustification: bothSlotsJustification,
            style: style,
            layout: layout,
            trailing: trailing,
            content: content
        )
    }

    /// A card that stands for one thing (a medication, a period): its name in
    /// the object name role, 17 pt, with an optional trailing element.
    public init(
        object name: Text,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        style: Style = .standard,
        layout: Layout = .free,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            heading: name,
            role: .objectName,
            subtitle: subtitle,
            footer: footer,
            bothSlotsJustification: nil,
            style: style,
            layout: layout,
            trailing: trailing,
            content: content
        )
    }

    private init(
        heading: Text?,
        role: HLTextRole,
        subtitle: LocalizedStringKey?,
        footer: LocalizedStringKey?,
        bothSlotsJustification: StaticString?,
        style: Style,
        layout: Layout,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        title = heading
        titleRole = role
        self.subtitle = subtitle
        self.footer = footer
        self.bothSlotsJustification = bothSlotsJustification
        self.style = style
        self.layout = layout
        self.trailing = trailing()
        self.content = content()
        warnOnDoubleSlot()
    }

    public var body: some View {
        if title == nil {
            surfaced
        } else {
            // A titled card is one group for VoiceOver: the title announces
            // it, the rows stay reachable one by one.
            surfaced.accessibilityElement(children: .contain)
        }
    }

    private var surfaced: some View {
        padded
            .frame(maxWidth: .infinity, alignment: .leading)
            .hlCardSurface(style)
    }

    private var hasHead: Bool {
        title != nil || subtitle != nil
    }

    @ViewBuilder
    private var padded: some View {
        switch layout {
        case .free:
            free.padding(HLLayout.cardInset)
        case .rows:
            rowCard.padding(.horizontal, HLLayout.cardInset)
        }
    }

    /// Head, content and footer in one stack inside the card inset, so the
    /// content ends as far from the lower edge as it stands from the sides.
    @ViewBuilder
    private var free: some View {
        if !hasHead, footer == nil {
            rows
        } else {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if title != nil {
                    header
                }
                subtitleText
                if title != nil {
                    Divider().opacity(0.6)
                }
                rows
                if let footer {
                    HLCardFooter(footer)
                }
            }
        }
    }

    /// Head and footer keep the card inset to the card's edge; the row block
    /// between them stands at half a row spacing, which makes it n row
    /// pitches high.
    private var rowCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHead {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if title != nil {
                        header
                    }
                    subtitleText
                }
                .padding(.top, HLLayout.cardInset)
                .padding(.bottom, HLSpace.md)
            }
            if title != nil {
                Divider().opacity(0.6)
            }
            rows.padding(.vertical, HLLayout.rowCardInsetVertical)
            if let footer {
                HLCardFooter(footer)
                    .padding(.top, HLSpace.xs)
                    .padding(.bottom, HLLayout.cardInset)
            }
        }
    }

    /// One stack for the content, so a card with several rows is one card and
    /// not one card per row.
    private var rows: some View {
        VStack(alignment: .leading, spacing: HLLayout.rowSpacing) {
            content
        }
    }

    /// The title row. At an accessibility size the trailing element drops
    /// below the title instead of squeezing it: a baseline-aligned pill next
    /// to a wrapped title has no baseline worth aligning to.
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                titleText
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                titleText
                Spacer(minLength: HLSpace.sm)
                trailing
            }
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if let title {
            title
                .hlText(titleRole)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Wraps at every text size; a subtitle too long for its card gets
    /// shorter, it is never cut.
    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Debug note when subtitle and footer are both set without a reason.
    /// A log line and not an assertion: the static count `hl_card_both_slots`
    /// in `UIStandardBaselineTests` is the hard rule, and its baseline can
    /// only shrink.
    private func warnOnDoubleSlot() {
        #if DEBUG
            guard subtitle != nil, footer != nil, bothSlotsJustification == nil else { return }
            HLLog.ui.debug("HLCard: subtitle and footer without bothSlotsJustification")
        #endif
    }
}

public extension HLCard where Trailing == EmptyView {
    /// A card that stands for one thing, without a trailing element.
    init(
        object name: Text,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        style: Style = .standard,
        layout: Layout = .free,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            object: name,
            subtitle: subtitle,
            footer: footer,
            style: style,
            layout: layout,
            trailing: { EmptyView() },
            content: content
        )
    }

    /// A card without a trailing element in its title row.
    init(
        _ title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        bothSlotsJustification: StaticString? = nil,
        style: Style = .standard,
        layout: Layout = .free,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            subtitle: subtitle,
            footer: footer,
            bothSlotsJustification: bothSlotsJustification,
            style: style,
            layout: layout,
            trailing: { EmptyView() },
            content: content
        )
    }
}

/// Footer line of a card: a consequence or a legal note under the rows.
struct HLCardFooter: View {
    private let footer: LocalizedStringKey

    init(_ footer: LocalizedStringKey) {
        self.footer = footer
    }

    var body: some View {
        Text(footer)
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, HLSpace.xs)
    }
}

public extension View {
    /// Surface and shape of a card without its inset, for content that runs
    /// to the card's edge (an image, a chart).
    func hlCardSurface(_ style: HLCardStyle = .standard) -> some View {
        modifier(HLCardSurfaceModifier(style: style))
    }
}

private struct HLCardSurfaceModifier: ViewModifier {
    let style: HLCardStyle

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch style {
        case .standard:
            filled(content)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(HLColor.separator.opacity(0.6), lineWidth: HLCardSurface.hairlineWidth)
                }
                .hlShadow(HLShadow.cardLight)
        case .outline:
            content
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(HLColor.separator, lineWidth: HLCardSurface.outlineWidth)
                }
        }
    }

    private func filled(_ content: Content) -> some View {
        content.background(HLSurface.secondary, in: shape)
    }
}

#Preview("HLCard, light") {
    HLCardPreview()
        .preferredColorScheme(.light)
}

#Preview("HLCard, dark") {
    HLCardPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLCard, largest type") {
    HLCardPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLCardPreview: View {
    var body: some View {
        HLPage {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("Today")
                        .font(.hlTitle3)
                    Text("Your day, on one card.")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
            }
            HLCard("Overview", footer: "No entries yet", layout: .rows) {
                HLSettingsToggleRow(title: "Blood pressure", description: nil, isOn: .constant(true))
                HLSettingsToggleRow(title: "Weight", description: nil, isOn: .constant(false))
            }
            HLCard("Sync", subtitle: "Every fifteen minutes", layout: .rows) {
                HLStatusPill(.connected(label: "Connected"))
            } content: {
                HLSettingsToggleRow(title: "Background sync", description: nil, isOn: .constant(true))
            }
            HLCard(layout: .rows) {
                HLSettingsToggleRow(title: "Pulse", description: nil, isOn: .constant(true))
                HLSettingsToggleRow(title: "Steps", description: nil, isOn: .constant(false))
            }
            HLCard(style: .outline) {
                Text("Overview")
                    .font(.hlBody)
            }
        }
    }
}
