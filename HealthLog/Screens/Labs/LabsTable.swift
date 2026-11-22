import SwiftUI

/// The cells right of the marker name in the labs table: the value with its
/// verdict and the value on its reference range, each in a column of its own
/// width, the same in every row, so the columns line up without titles.
///
/// The widths follow the text size, so a larger setting makes the columns
/// wider instead of cutting what stands in them; at the sizes where that no
/// longer fits ``LabsTableLayout`` takes the columns away.
struct LabsTableCells<Value: View, Range: View>: View {
    let columns: [LabsTableLayout.Column]
    @ViewBuilder let value: () -> Value
    @ViewBuilder let range: () -> Range

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The widths the layout rule counts with, so the rule and the row agree.
    var body: some View {
        HStack(alignment: .center, spacing: HLLayout.rowGap) {
            if columns.contains(.value) {
                value().frame(width: LabsTableLayout.valueWidth(typeSize), alignment: .trailing)
            }
            if columns.contains(.range) {
                range().frame(width: LabsTableLayout.rangeWidth(typeSize))
            }
        }
    }
}

/// One marker as a row of the table: the name with its count and date, then
/// the value with the server's verdict, then the value on its range with the
/// earlier readings as faint points.
///
/// The marker name wraps instead of being cut, because the Dutch and English
/// names are the longer ones; the value scales down a little before it wraps.
struct LabMarkerTableRow: View {
    let entry: LabsStore.MarkerIndexEntry
    let columns: [LabsTableLayout.Column]
    /// The catalogue marker the row stands for, so its range is the one the
    /// marker page judges against.
    var marker: BiomarkerDTO?
    /// The row's ground, so the ring around the value point matches it.
    var surface: Color = HLSurface.secondary

    var body: some View {
        HLRowLayout(
            title: Text(verbatim: entry.name),
            subtitle: HLRowDetail.text(detailParts),
            indicator: .hidden,
            configuration: .labsTable,
            leading: { EmptyView() },
            trailing: { cells }
        )
        .accessibilityLabel(accessibilityText)
    }

    private var cells: some View {
        LabsTableCells(columns: columns) {
            HLRowValue(
                Text(verbatim: entry.latest.displayValue),
                status: entry.latest.rangeStatus.rowStatus
            )
            .minimumScaleFactor(0.8)
        } range: {
            // Without a range or a number the cell still holds its column,
            // so the value stands where it stands in every other row.
            let bounds = LabRangeScale.bounds(marker: marker, latest: entry.latest)
            if let bar = LabRangeBar(
                value: entry.latest.value,
                previous: LabsTableLayout.earlierValues(entry.trend),
                low: bounds.low,
                high: bounds.high,
                accessibilityText: reference ?? "",
                surface: surface
            ) {
                bar.accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var reference: String? {
        LabsTableLayout.referenceText(for: entry.latest)
    }

    /// Count and date; the range is the bar beside them.
    private var detailParts: [String?] {
        [
            BiomarkerIndexRow.countCaption(entry.count),
            LabsDateFormat.labDate(entry.latest.takenAt)
        ]
    }

    private var accessibilityText: String {
        let template = String(localized: "labs.row.a11y")
        let base = String(
            format: template,
            entry.name,
            entry.latest.displayValue,
            entry.latest.rangeStatus.localizedLabel
        )
        guard let reference else { return base }
        return "\(base), \(String(localized: "labs.detail.reference")) \(reference)"
    }
}

extension HLRowConfiguration {
    /// A table row: the name and the detail line wrap at every size instead
    /// of being cut, the cells on the right keep the width of their column.
    static var labsTable: HLRowConfiguration {
        HLRowConfiguration(stacking: .never, trailingFit: .intrinsic, limitsLines: false)
    }
}
