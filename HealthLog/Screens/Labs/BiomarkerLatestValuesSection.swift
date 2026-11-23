import SwiftUI

/// The newest readings of a marker under its chart (#191 QoL, the web's
/// `LabLatestValues`): "What was my LDL last time?" is answered on the page.
///
/// One card of history rows, newest first, at most ``shownCount``; each opens
/// the reading. The row to every reading of the period stays the card's last
/// row, so the page keeps one block for its readings.
struct BiomarkerLatestValuesSection: View {
    let store: LabsStore
    /// Every reading of the marker, newest first.
    let rows: [LabResultDTO]
    /// The readings of the chosen period, for the row to all of them.
    let windowedRows: [LabResultDTO]
    let title: String

    /// The web's `LATEST_VALUES_SHOWN`.
    nonisolated static let shownCount = 5

    /// The rows the card lists: the newest readings, at most ``shownCount``.
    nonisolated static func latest(_ rows: [LabResultDTO]) -> [LabResultDTO] {
        Array(rows.prefix(shownCount))
    }

    var body: some View {
        if !rows.isEmpty {
            let inPeriod = !windowedRows.isEmpty
            HLSectionHeader("biomarker.detail.latestValues", rank: .area)
            HLCard(layout: .rows) {
                ForEach(Self.latest(rows)) { row in
                    HLHistoryRow(
                        date: Text(verbatim: LabsDateFormat.mediumDate(row.takenAt)),
                        detail: LabConversion(row).convertedLine.map { Text(verbatim: $0) },
                        value: Text(verbatim: row.displayValue),
                        status: row.rangeStatus.rowStatus
                    )
                    .hlRowLink {
                        LabResultDetailScreen(store: store, resultID: row.id, summary: row)
                    }
                    .accessibilityIdentifier("biomarker.detail.latest.\(row.id)")
                }
                HLDrillRow(
                    "Show all measurements",
                    count: windowedRows.count,
                    hasEntriesOutsidePeriod: !inPeriod
                )
                .hlRowLink(value: LabHistoryRoute(title: title, rows: inPeriod ? windowedRows : rows))
                .accessibilityIdentifier("biomarker.detail.showAll")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("biomarker.detail.latestValues")
        }
    }
}
