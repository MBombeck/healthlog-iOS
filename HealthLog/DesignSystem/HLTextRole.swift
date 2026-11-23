import SwiftUI

/// The job a piece of text has on a page.
///
/// A screen names the job (`.hlText(.rowTitle)`) and the role brings face,
/// weight and colour, so the same job has the same look on every screen and
/// on every device. Screens set no font and no text colour of their own.
///
/// The room before and after a role is published in ``HLTextRoleSpec`` and
/// laid out by the building block that owns the role (``HLTabHeader``,
/// ``HLSectionHeader``, ``HLColumnHeader``, ``HLCard``); `.hlText` itself adds
/// no padding, so a text can take a role inside any stack without moving.
public enum HLTextRole: String, CaseIterable, Sendable {
    /// Large title of a tab or section root (``HLTabHeader``).
    case pageTitle
    /// The line under the page title.
    case pageSubtitle
    /// Name of the selection in a detail column beside a list (``HLColumnHeader``).
    case columnHeader
    /// Header of one of the large parts of a page (``HLSectionHeader``, rank area).
    case areaHeader
    /// Header of a group inside an area, every settings header.
    case groupHeader
    /// Title over a table column, in the style of a group header.
    case tableColumnTitle
    /// Name of the one thing a card stands for (a medication, a period).
    case objectName
    /// Title of a row card that is a rubric rather than a thing.
    case cardTitle
    /// Label of a tile, with its symbol before it.
    case tileLabel
    /// The one large value of a page or column.
    case heroValue
    /// The value of a tile.
    case tileValue
    /// A value in a cell, a vital row or a ring.
    case compactValue
    /// Unit beside a hero or tile value.
    case valueUnit
    /// Unit beside a compact value.
    case compactUnit
    /// Title of a row.
    case rowTitle
    /// The line under a row title.
    case rowSubtitle
    /// The value at the trailing edge of a row.
    case rowValue
    /// The status line under a row value.
    case rowStatus
    /// The label of a fact pair.
    case factLabel
    /// The value of a fact pair.
    case factValue
    /// Running text: a day sentence, a summary.
    case prose
    /// A note inside a card or under a control.
    case note
    /// Sources and legal lines at the foot of a card.
    case footnote
    /// Tick labels of a chart axis.
    case chartAxis
    /// The unit at the top of a chart's value axis.
    case chartUnit
    /// A label inside the plot (a bar label, "Today").
    case chartMark
    /// Title of an empty state.
    case emptyTitle
    /// Message of an empty state.
    case emptyMessage

    /// What the role sets, at the text size "Large".
    public var spec: HLTextRoleSpec {
        switch self {
        case .pageTitle: HLTextRoleSpec(.largeTitle, .bold, .primary, before: HLLayout.pageTop, after: HLSpace.xxs)
        case .pageSubtitle: HLTextRoleSpec(.subheadline, .regular, .secondary, before: HLSpace.xxs)
        case .columnHeader: HLTextRoleSpec(.headline, .semibold, .primary, before: 0, after: HLSpace.xxs)
        case .areaHeader: HLTextRoleSpec(.headline, .semibold, .primary, before: HLLayout.sectionGapBefore, after: HLLayout.sectionGapAfter)
        case .groupHeader, .tableColumnTitle:
            HLTextRoleSpec(.footnote, .semibold, .secondary, before: HLLayout.sectionGapBefore, after: HLLayout.sectionGapAfter)
        case .objectName: HLTextRoleSpec(.headline, .semibold, .primary, before: HLLayout.cardInset, after: HLSpace.md)
        case .cardTitle: HLTextRoleSpec(.subheadline, .semibold, .primary, before: HLLayout.cardInset, after: HLSpace.md)
        case .tileLabel: HLTextRoleSpec(.caption, .semibold, .secondary, before: HLLayout.cardInset, after: HLSpace.xs)
        case .heroValue: HLTextRoleSpec(
                .largeTitle,
                .bold,
                .primary,
                design: .rounded,
                digits: true,
                before: HLLayout.cardInset,
                after: HLSpace.xs
            )
        case .tileValue: HLTextRoleSpec(.title, .bold, .primary, design: .rounded, digits: true, before: HLSpace.xs, after: HLSpace.sm)
        case .compactValue: HLTextRoleSpec(.body, .bold, .primary, design: .rounded, digits: true)
        case .valueUnit: HLTextRoleSpec(.subheadline, .regular, .secondary)
        case .compactUnit: HLTextRoleSpec(.caption, .regular, .secondary)
        case .rowTitle: HLTextRoleSpec(.subheadline, .semibold, .primary)
        case .rowSubtitle: HLTextRoleSpec(.caption, .regular, .secondary, before: HLSpace.xxs)
        case .rowValue: HLTextRoleSpec(.subheadline, .medium, .primary, digits: true)
        case .rowStatus: HLTextRoleSpec(.caption, .regular, .secondary)
        case .factLabel: HLTextRoleSpec(.subheadline, .regular, .secondary)
        case .factValue: HLTextRoleSpec(.subheadline, .regular, .primary)
        case .prose: HLTextRoleSpec(.subheadline, .regular, .primary)
        case .note: HLTextRoleSpec(.footnote, .regular, .secondary, before: HLSpace.xs)
        case .footnote: HLTextRoleSpec(.caption, .regular, .tertiary, before: HLSpace.xs)
        case .chartAxis: HLTextRoleSpec(.caption, .regular, .secondary)
        case .chartUnit: HLTextRoleSpec(.caption, .semibold, .secondary)
        case .chartMark: HLTextRoleSpec(.caption2, .medium, .secondary)
        case .emptyTitle: HLTextRoleSpec(.headline, .semibold, .primary)
        case .emptyMessage: HLTextRoleSpec(.subheadline, .regular, .secondary)
        }
    }

    /// The font of the role, scaled with Dynamic Type.
    public var font: Font {
        let spec = spec
        let base = Font.system(spec.style, design: spec.design.font, weight: spec.weight.font)
        return spec.fixedDigits ? base.monospacedDigit() : base
    }

    /// The colour of the role.
    public var color: Color {
        spec.tone.color
    }
}

/// The frozen measures of one text role. Plain values, so the contract test
/// compares them without rendering.
public struct HLTextRoleSpec: Equatable, Sendable {
    /// Weight, as a value that compares.
    public enum Weight: String, Equatable, Sendable {
        case regular, medium, semibold, bold

        var font: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    /// Face, as a value that compares.
    public enum Design: String, Equatable, Sendable {
        case standard, rounded

        var font: Font.Design {
            self == .rounded ? .rounded : .default
        }
    }

    /// Text colour, as a value that compares.
    public enum Tone: String, Equatable, Sendable {
        case primary, secondary, tertiary

        var color: Color {
            switch self {
            case .primary: HLText.primary
            case .secondary: HLText.secondary
            case .tertiary: HLText.tertiary
            }
        }
    }

    public let style: Font.TextStyle
    public let weight: Weight
    public let tone: Tone
    public let design: Design
    /// Digits of equal width, so a changing value does not jitter.
    public let fixedDigits: Bool
    /// Room above, laid out by the owning building block.
    public let before: CGFloat
    /// Room below, laid out by the owning building block.
    public let after: CGFloat

    init(
        _ style: Font.TextStyle,
        _ weight: Weight,
        _ tone: Tone,
        design: Design = .standard,
        digits: Bool = false,
        before: CGFloat = 0,
        after: CGFloat = 0
    ) {
        self.style = style
        self.weight = weight
        self.tone = tone
        self.design = design
        fixedDigits = digits
        self.before = before
        self.after = after
    }
}

public extension View {
    /// Sets the face, weight and colour of a text role.
    func hlText(_ role: HLTextRole) -> some View {
        font(role.font).foregroundStyle(role.color)
    }

    /// A text role whose colour carries a state (a critical row title, a
    /// status line): the role's face, the state's colour.
    func hlText(_ role: HLTextRole, status: Color) -> some View {
        font(role.font).foregroundStyle(status)
    }
}
