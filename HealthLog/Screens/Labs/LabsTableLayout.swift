import SwiftUI

/// Which columns the labs list shows at a measured width and text size.
///
/// Pure, so the rule can be tested at every width. Compact stays the list of
/// rows it always was (marker, value and its range as quiet text on the
/// right); from a regular width on the same rows become a table: the name
/// with its date, the value with its verdict, and the value on its reference
/// range. Each row says what its cells are, so the table has no column titles.
enum LabsTableLayout {
    enum Column: Equatable, CaseIterable {
        case marker
        case value
        case range
    }

    /// Narrowest list alone on the screen that turns into a table, so a
    /// phone, a Duo folded and a narrow window keep the rows they had.
    static let tableMinimum: CGFloat = 520
    /// Narrowest list beside its detail that turns into a table.
    static let besideMinimum: CGFloat = HLListDetailLayout.listMinimum
    /// The least room the marker name keeps beside the cells: below it a
    /// name breaks into single syllables, so the list stays plain rows.
    static let nameMinimum: CGFloat = 140

    /// Width of the value column at the default size: a value with its
    /// verdict under it.
    static let valueBase: CGFloat = 104
    /// Width of the range column at the default size: a bar wide enough
    /// for its two bounds.
    static let rangeBase: CGFloat = 120

    /// The value column at a text size; it grows with the subheadline.
    static func valueWidth(_ typeSize: DynamicTypeSize) -> CGFloat {
        (valueBase * scale(typeSize, points: subheadlinePoints)).rounded()
    }

    /// The range column at a text size; it grows with its caption2 bounds.
    static func rangeWidth(_ typeSize: DynamicTypeSize) -> CGFloat {
        (rangeBase * scale(typeSize, points: caption2Points)).rounded()
    }

    /// The room the marker name keeps in a list of `listWidth`: the page
    /// margins and the row's insets on both sides, the cells and their gaps.
    static func nameWidth(listWidth: CGFloat, typeSize: DynamicTypeSize) -> CGFloat {
        listWidth - 2 * HLLayout.pageMargin - 2 * HLLayout.cardInset
            - valueWidth(typeSize) - rangeWidth(typeSize) - 2 * HLLayout.rowGap
    }

    /// The columns of the table, or `[]` where the list stays a list of
    /// plain rows: below the minimum width, where the name would keep less
    /// than ``nameMinimum``, from the first accessibility size on (two
    /// columns are the plain row already), and while the width is not known.
    static func columns(_ layout: HLListDetailLayout.Resolution, typeSize: DynamicTypeSize) -> [Column] {
        let width = layout.listWidth
        guard width > 0, typeSize < .accessibility1 else { return [] }
        let minimum = layout.isSideBySide ? besideMinimum : tableMinimum
        guard width >= minimum, nameWidth(listWidth: width, typeSize: typeSize) >= nameMinimum else { return [] }
        return Column.allCases
    }

    /// Point sizes of the text styles at the standard sizes, as the system
    /// sets them; the columns scale like the text in them.
    private static let subheadlinePoints: [DynamicTypeSize: CGFloat] = [
        .xSmall: 12, .small: 13, .medium: 14, .large: 15, .xLarge: 17, .xxLarge: 19, .xxxLarge: 21
    ]
    private static let caption2Points: [DynamicTypeSize: CGFloat] = [
        .xSmall: 11, .small: 11, .medium: 11, .large: 11, .xLarge: 13, .xxLarge: 15, .xxxLarge: 17
    ]

    private static func scale(_ typeSize: DynamicTypeSize, points: [DynamicTypeSize: CGFloat]) -> CGFloat {
        guard let base = points[.large], let size = points[typeSize] else {
            // Accessibility sizes have no table; take the largest standard step.
            return (points[.xxxLarge] ?? 1) / (points[.large] ?? 1)
        }
        return size / base
    }

    /// The columns and the arrangement for a window width, in one step.
    static func resolve(
        width: CGFloat?,
        typeSize: DynamicTypeSize
    ) -> (layout: HLListDetailLayout.Resolution, columns: [Column]) {
        let layout = HLListDetailLayout.resolve(width: width, typeSize: typeSize)
        return (layout, columns(layout, typeSize: typeSize))
    }

    /// The reference range as text: the bounds with the unit, `nil` without
    /// any bound.
    static func referenceText(for latest: LabResultDTO) -> String? {
        BiomarkerSeries.referenceText(low: latest.referenceLow, high: latest.referenceHigh, unit: latest.unit)
    }

    /// The readings before the newest one, oldest first: the overview's
    /// trend ends with the newest reading, and qualitative ones have no place.
    static func earlierValues(_ trend: [Double?]) -> [Double] {
        trend.dropLast().compactMap(\.self)
    }
}
