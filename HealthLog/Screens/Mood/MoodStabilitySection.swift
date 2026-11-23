import SwiftUI

/// Stability and entry count in the statistic raster every detail page uses
/// (`HLStatGrid`), so the mood page states its key figures the way the
/// metric pages state Min, Ø and Max.
///
/// The stability cell carries the server's score and its band in a word; it
/// is absent while the server has none for the period (#115 · 1.3, no client
/// computation). The entry count stands whenever the window holds an entry.
struct MoodStabilitySection: View {
    let stability: MoodStability?
    /// Entry count + window-length string for the paired cell.
    let entryCount: Int
    let windowLabel: String

    var body: some View {
        let cells = Self.cells(stability: stability, entryCount: entryCount, windowLabel: windowLabel)
        if !cells.isEmpty {
            HLStatGrid(cells: cells)
                .accessibilityIdentifier("mood.statistics")
        }
    }

    /// The raster's cells: stability first, then the entries; a figure the
    /// period does not have is left out rather than shown as zero.
    nonisolated static func cells(stability: MoodStability?, entryCount: Int, windowLabel: String) -> [HLStatCell] {
        var cells: [HLStatCell] = []
        if let stability {
            cells.append(HLStatCell(
                label: String(localized: "Stability"),
                value: HLValueFormat.number(Double(stability.score), fractionDigits: 0 ... 0),
                unit: bandLabel(for: stability.band)
            ))
        }
        if entryCount > 0 {
            cells.append(HLStatCell(
                label: String(localized: "Entries"),
                value: HLValueFormat.number(Double(entryCount), fractionDigits: 0 ... 0),
                unit: windowLabel
            ))
        }
        return cells
    }

    // MARK: - Band copy

    nonisolated static func bandLabel(for band: MoodStability.Band) -> String {
        switch band {
        case .verySteady: String(localized: "Very steady")
        case .steady: String(localized: "Steady")
        case .variable: String(localized: "Variable")
        case .veryVariable: String(localized: "mood.stability.band.veryVariable")
        case .unknown: String(localized: "mood.stability.band.unknown")
        }
    }

    /// "Stabil über 30 Tage": the band in a word, then the server's window.
    nonisolated static func caption(for stability: MoodStability) -> String {
        String(format: String(localized: "mood.stability.caption"), bandLabel(for: stability.band), stability.days)
    }
}
