import SwiftUI

/// One key figure of a statistic: a label over a value, the unit under it.
struct HLStatCell: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    /// `nil` or empty draws no unit line.
    var unit: String?

    var id: String {
        label
    }
}

/// **The statistic raster of every detail page**, as on the reference metric
/// page: Min, Ø, Max, Median (or any other key figures: stability, entries,
/// cycle length), each in a recessed cell, side by side. A page with two
/// series (blood pressure) stacks one row per series, each under a small
/// heading.
///
/// The cells of one row share one height, whichever label breaks onto a
/// second line. A label takes at most two lines, so a word moves to the next
/// line whole instead of falling apart into syllables. From the accessibility
/// sizes on the cells stand two by two and their text wraps instead of
/// shrinking, so nothing is cut.
struct HLStatGrid: View {
    /// One row of cells under an optional heading.
    struct Section: Identifiable, Equatable, Sendable {
        var title: String?
        let cells: [HLStatCell]

        var id: String {
            (title ?? "") + cells.map(\.label).joined(separator: "|")
        }
    }

    let sections: [Section]

    /// One row, optionally under a heading.
    init(cells: [HLStatCell], title: String? = nil) {
        sections = [Section(title: title, cells: cells)]
    }

    /// Several rows, each under its heading (systolic over diastolic).
    init(sections: [Section]) {
        self.sections = sections
    }

    /// From the accessibility sizes on the cells stand two by two.
    static func stacks(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// Cells per row: all of them side by side, two from the accessibility
    /// sizes on.
    static func columns(for count: Int, at size: DynamicTypeSize) -> Int {
        max(1, stacks(size) ? min(2, count) : count)
    }

    /// Cells per row at a measured `width`, through the same column rule as
    /// ``HLAdaptiveGrid``: as many as fit, never more than ``columns(for:at:)``.
    /// Unmeasured (`nil`) it is ``columns(for:at:)``.
    static func columns(for count: Int, at size: DynamicTypeSize, width: CGFloat?) -> Int {
        let maximum = columns(for: count, at: size)
        guard let width else { return maximum }
        return HLAdaptiveGrid.columns(
            width: width,
            minimum: HLLayout.statCellMinWidth,
            maximum: maximum,
            spacing: HLLayout.statCellGap
        )
    }

    /// The cells cut into rows of `columns`.
    static func rows(_ cells: [HLStatCell], columns: Int) -> [[HLStatCell]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: cells.count, by: columns).map {
            Array(cells[$0 ..< min($0 + columns, cells.count)])
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The gap of the page around the grid; the first heading counts it.
    @Environment(\.hlContainerGap) private var containerGap
    /// The grid's own width. The column count changes only its height.
    @State private var width: CGFloat?

    /// The gap a heading of the grid stands in: the first one hears the
    /// page's gap above it, a later one follows a row of cells directly.
    /// Below each heading come the cells, with nothing in between.
    static func headingGap(isFirst: Bool, page: HLContainerGap) -> HLContainerGap {
        HLContainerGap(before: isFirst ? page.before : 0, after: 0)
    }

    var body: some View {
        let shown = sections.filter { !$0.cells.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, section in
                if let title = section.title, !title.isEmpty {
                    // A series heading is a group header: 13 semibold, 24
                    // above, 8 below, as everywhere else.
                    HLSectionHeader(verbatim: title, rank: .group)
                        .environment(\.hlContainerGap, Self.headingGap(isFirst: index == 0, page: containerGap))
                } else if index > 0 {
                    Color.clear.frame(height: HLLayout.statCellGap)
                }
                row(section.cells)
            }
        }
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// A `Grid`, so every cell of a row takes the height of the tallest.
    private func row(_ cells: [HLStatCell]) -> some View {
        let columns = Self.columns(for: cells.count, at: dynamicTypeSize, width: width)
        let rows = Self.rows(cells, columns: columns)
        return Grid(alignment: .top, horizontalSpacing: HLLayout.statCellGap, verticalSpacing: HLLayout.statCellGap) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { cell in
                        HLStatTile(cell: cell)
                    }
                    // A short last row keeps the width of the full ones.
                    ForEach(rows[index].count ..< columns, id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}

/// One cell of ``HLStatGrid``: label 12 secondary, value 17 rounded mono,
/// unit 12 tertiary, on the recessed surface.
struct HLStatTile: View {
    let cell: HLStatCell
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(cell: HLStatCell) {
        self.cell = cell
    }

    init(label: String, value: String, unit: String) {
        cell = HLStatCell(label: label, value: value, unit: unit)
    }

    /// Most lines a label takes; a word that does not fit moves down whole.
    static let labelLineLimit = 2

    /// Lines a value takes: one, or one per part of a length of time
    /// written over two lines ("6 Std." over "47 Min."), never cut.
    static func valueLineLimit(_ value: String) -> Int {
        value.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// What VoiceOver reads: label, value, unit.
    static func spokenText(_ cell: HLStatCell) -> String {
        [cell.label, cell.value, cell.unit].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
    }

    var body: some View {
        // Up to four cells share a 393 pt row (~90 pt each): the value on one
        // line, scaled down rather than wrapped, the label on up to two;
        // from the accessibility sizes on the grid is 2 x 2 and the text
        // wraps instead, never cut.
        let wraps = dynamicTypeSize.isAccessibilitySize
        VStack(spacing: HLSpace.xxs) {
            Text(cell.label).font(.hlCaption).foregroundStyle(HLText.secondary)
                .lineLimit(wraps ? nil : Self.labelLineLimit).minimumScaleFactor(wraps ? 1 : 0.7)
            Text(cell.value).font(.hlMetric(.headline)).foregroundStyle(HLText.primary).monospacedDigit()
                .lineLimit(wraps ? nil : Self.valueLineLimit(cell.value)).minimumScaleFactor(wraps ? 1 : 0.7)
                .hlNumericChange(cell.value)
            if let unit = cell.unit, !unit.isEmpty {
                Text(unit).font(.hlCaption).foregroundStyle(HLText.tertiary)
                    .lineLimit(wraps ? nil : 1).minimumScaleFactor(wraps ? 1 : 0.7)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.sm)
        // Takes the height of the row it stands in, so neighbours match.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spokenText(cell)))
    }
}

#Preview("HLStatGrid") {
    VStack(spacing: HLSpace.lg) {
        HLStatGrid(cells: [
            HLStatCell(label: "Min", value: "52", unit: "bpm"),
            HLStatCell(label: "Ø", value: "61", unit: "bpm"),
            HLStatCell(label: "Max", value: "74", unit: "bpm"),
            HLStatCell(label: "Median", value: "60", unit: "bpm")
        ])
        HLStatGrid(sections: [
            .init(title: "Systolisch", cells: [HLStatCell(label: "Min", value: "112", unit: "mmHg")]),
            .init(title: "Diastolisch", cells: [HLStatCell(label: "Min", value: "71", unit: "mmHg")])
        ])
    }
    .padding()
    .background(HLSurface.primary)
}
