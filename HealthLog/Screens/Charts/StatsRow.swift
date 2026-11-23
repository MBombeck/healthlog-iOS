import SwiftUI

// The Min / Ø / Max / Median row of the metric page, lifted out
// of `ChartDetailComponents.swift` (1.4 B2, file_length: pure code movement).

// MARK: - Stats summary row (Apple-Health-style)

/// Four-card statistic summary — Min, Ø (mean), Max, Median.
///
/// Median is the additive Charlie-v0.4.0 stat (the prior row showed σ, which
/// is information-dense but less actionable for end users; Apple Health uses
/// Min/Avg/Max + an "Auf einen Blick" median-equivalent). Median is computed
/// on-device from the rendered series via `ChartDetailStore.median`. σ stays
/// available in `SeriesStats` for future deep-dives but isn't surfaced here.
struct StatsRow: View {
    let stats: SeriesStats?
    let median: Double?
    let unit: String
    /// The metric kind drives unit conversion of the stats. Default
    /// `nil` keeps existing call-sites compiling and renders the raw value (the
    /// pre-fix behaviour) until they pass a kind; the in-app call-sites all pass
    /// it so weight/BP convert. Glucose stats are already server-converted.
    var kind: MetricKind?
    var units: UnitPreferences = .standard

    var body: some View {
        if stats != nil {
            // The raster is the design system's `HLStatGrid`; this row only
            // turns a series' stats into its cells.
            HLStatGrid(cells: cells)
        }
    }

    /// The row's cells, also for a page that stacks several rows in one
    /// ``HLStatGrid`` (systolic over diastolic). Empty without stats.
    var cells: [HLStatCell] {
        guard let stats else { return [] }
        // A duration (sleep) reads "7 h 12 min" and names its units itself:
        // the long form does not fit a quarter of the row.
        let cellUnit = kind.map { MetricDurationFormat.cellUnit(unit, kind: $0) } ?? unit
        return Self.boxes(stats: stats, median: median, format: format).map {
            HLStatCell(label: $0.label, value: $0.value, unit: cellUnit)
        }
    }

    /// From the accessibility sizes on the boxes stand two by two.
    static func stacks(_ size: DynamicTypeSize) -> Bool {
        HLStatGrid.stacks(size)
    }

    /// Min, mean, max and, when there is one, the median, in that order.
    static func boxes(stats: SeriesStats, median: Double?, format: (Double) -> String) -> [Box] {
        [
            Box(label: String(localized: "Min"), value: format(stats.min)),
            Box(label: String(localized: "chart.stat.mean"), value: format(stats.mean)),
            Box(label: String(localized: "Max"), value: format(stats.max))
        ] + (median.map { [Box(label: String(localized: "chart.stat.median"), value: format($0))] } ?? [])
    }

    struct Box: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String {
            label
        }
    }

    /// Converts a stat into the user's unit. Series stats are canonical for
    /// weight/BP (convert) and already server-converted for glucose (pass
    /// through), mirroring the hero/point formatter. Falls back to the prior
    /// raw 0…1-dp rendering when no `kind` is supplied.
    ///
    /// **BH-final-diff H6/M5** — the precision per family must match the
    /// hero/callout EXACTLY so the same chart screen never disagrees with
    /// itself. Weight uses 1-dp (the dashboard/hero canonical `fractionLength(1)`
    /// → `80.0`); BP is integer-grained for mmHg and 1-dp for kPa (a single
    /// leg's value, since the stats row renders systolic/diastolic separately).
    private func format(_ v: Double) -> String {
        guard let kind else {
            return HLValueFormat.number(v, fractionDigits: 0 ... 1)
        }
        if let duration = MetricDurationFormat.cell(v, kind: kind) {
            return duration
        }
        // One central account-unit formatter. Series glucose is
        // already server-converted (passed through); every other family
        // converts from canonical SI; the identity branch keeps 0…1 dp.
        // BP renders one leg at a time here: mmHg integer, kPa 1-dp.
        return MetricValueFormatter.account(v, kind: kind, units: units, glucose: .seriesPreConvertedGlucose) {
            HLValueFormat.number($0, fractionDigits: 0 ... 1)
        }
    }
}

/// One cell of the raster, now ``HLStatTile`` in the design system.
typealias StatBox = HLStatTile
