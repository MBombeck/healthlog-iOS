import SwiftUI

/// The key figures of the metric page as a compact table under the chart:
/// one row per series (systolic over diastolic, or the one series), one
/// column per figure (Min, Ø, Max, Median), the column titles in the group
/// header style on the line above.
///
/// Named rows (a pressure) get a name column, as wide as its words, with the
/// unit above the names. The one series of a page has no name column: four
/// equal columns, the unit small after each value.
///
/// A table and not a raster of tiles: the figures of one series stand on
/// one line, so a pressure reads systolic and diastolic side by side and the
/// chart above keeps the room. From the accessibility sizes on, every row
/// stands as a stack of label and value pairs instead.
struct MetricStatsTable: View {
    let rows: [Row]

    /// One series: its name (empty for the only series of a page) and its
    /// figures in column order.
    struct Row: Identifiable, Equatable {
        let title: String
        let cells: [HLStatCell]

        var id: String {
            title
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The column titles, from the first row with figures.
    static func columnTitles(_ rows: [Row]) -> [String] {
        rows.first?.cells.map(\.label) ?? []
    }

    /// The unit of the figures, said once in the header's leading cell.
    static func unit(_ rows: [Row]) -> String {
        rows.lazy.flatMap(\.cells).compactMap(\.unit).first { !$0.isEmpty } ?? ""
    }

    /// Whether the table has a name column: only when a row has a name.
    static func showsNameColumn(_ rows: [Row]) -> Bool {
        rows.contains { !$0.title.isEmpty }
    }

    /// The unit after each value: none with a name column, where the unit
    /// heads the names instead; `nil` without a unit.
    static func valueUnit(_ rows: [Row]) -> String? {
        let unit = unit(rows)
        return showsNameColumn(rows) || unit.isEmpty ? nil : unit
    }

    var body: some View {
        if !rows.isEmpty {
            HLCard {
                if dynamicTypeSize.isAccessibilitySize {
                    stacked
                } else {
                    table
                }
            }
            .accessibilityIdentifier("insights.metric.statsTable")
        }
    }

    private var table: some View {
        let named = Self.showsNameColumn(rows)
        let valueUnit = Self.valueUnit(rows)
        return Grid(alignment: .trailing, horizontalSpacing: HLSpace.md, verticalSpacing: HLSpace.md) {
            GridRow {
                // The name column is as wide as its words and never cut;
                // the figure columns share the rest evenly.
                if named {
                    Text(verbatim: Self.unit(rows))
                        .hlText(.tableColumnTitle)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                }
                ForEach(Self.columnTitles(rows), id: \.self) { title in
                    Text(verbatim: title)
                        .hlText(.tableColumnTitle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .accessibilityHidden(true)
            ForEach(rows) { row in
                GridRow {
                    if named {
                        Text(verbatim: row.title)
                            .hlText(.rowTitle)
                            .fixedSize()
                    }
                    ForEach(row.cells) { cell in
                        valueCell(cell.value, unit: valueUnit)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spoken(row)))
            }
        }
    }

    /// A figure, with the unit small after it where the table has no name
    /// column. A length of time stands on two lines, hours over minutes.
    private func valueCell(_ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xxs) {
            Text(verbatim: value)
                .hlText(.rowValue)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            if let unit {
                Text(verbatim: unit)
                    .hlText(.rowSubtitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Label and value pairs under each series' name, for the large sizes.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    if !row.title.isEmpty {
                        Text(verbatim: row.title)
                            .hlText(.rowTitle)
                    }
                    ForEach(row.cells) { cell in
                        HLFactRow(
                            label: Text(verbatim: cell.label),
                            value: Text(verbatim: [Self.oneLine(cell.value), cell.unit ?? ""].joined(separator: " "))
                        )
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spoken(row)))
            }
        }
    }

    /// "Systolisch, Min 110 mmHg, Ø 122 mmHg, …" for VoiceOver.
    static func spoken(_ row: Row) -> String {
        let figures = row.cells.map { cell in
            [cell.label, oneLine(cell.value), cell.unit ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ([row.title].filter { !$0.isEmpty } + figures).joined(separator: ", ")
    }

    /// A value stacked for a narrow cell, on one line again.
    static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }
}
