import Foundation

/// Pure value helpers backing the Insights-class biomarker
/// detail page. Everything here is a derivation of the already-loaded
/// `LabsStore.labs` (`[LabResultDTO]`) — no new server endpoint, no recompute of
/// any server verdict. A per-biomarker series is a filter of that list; the
/// stats / median are computed on-device exactly as the Insights metric page
/// computes its median from the rendered series.
///
/// **NEUTRAL contract.** None of these helpers re-derive `rangeStatus` — that
/// stays the singular server verdict carried on each `LabResultDTO`. The chart's
/// reference band uses the server-resolved `referenceLow`/`referenceHigh` only as
/// a calm visual rail (never a red alarm).
enum BiomarkerSeries {
    /// The detail page's window: the app's one period set (T, W, M, 6M, J,
    /// Alle). `rawValue` is the window in days and doubles as the `windowed`
    /// cutoff; `.all` passes every reading through.
    typealias LabsRange = HLTimeRange

    /// All rows for a single analyte name (the "by type" identity), newest-first.
    /// Pure filter of the loaded list — no recompute. An empty `analyte` never
    /// matches (the blank-analyte bucket is handled by the index, not the detail
    /// page). Comparison is case-insensitive so a label-cased analyte still
    /// resolves its readings.
    static func rows(forAnalyte analyte: String, in labs: [LabResultDTO]) -> [LabResultDTO] {
        guard !analyte.isEmpty else { return [] }
        return labs
            .filter { $0.analyte.localizedCaseInsensitiveCompare(analyte) == .orderedSame }
            .sorted { $0.takenAt > $1.takenAt }
    }

    /// All rows linked to a catalog biomarker id, newest-first. Pure filter.
    static func rows(forBiomarkerId id: String, in labs: [LabResultDTO]) -> [LabResultDTO] {
        labs
            .filter { $0.biomarkerId == id }
            .sorted { $0.takenAt > $1.takenAt }
    }

    /// Filter `rows` to those collected within `range` of `now`. `.all` is a
    /// no-op pass-through. Rows whose `takenAt` fails to parse are KEPT (we never
    /// silently drop a reading because of a malformed wire timestamp — they sort
    /// to the front via the lexicographic newest-first order upstream).
    static func windowed(
        _ rows: [LabResultDTO],
        range: LabsRange,
        now: Date = .now
    ) -> [LabResultDTO] {
        guard range != .all else { return rows }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: now) else {
            return rows
        }
        return rows.filter { row in
            guard let date = LabsDateFormat.readingDate(row.takenAt) else { return true }
            return date >= cutoff
        }
    }

    /// The period a marker page opens on: the app's standard when it already
    /// holds two values to draw, else the next wider period that does, else
    /// every reading. A marker measured twice months apart never opens on an
    /// empty chart.
    static func openingRange(for rows: [LabResultDTO], now: Date = .now) -> LabsRange {
        let candidates = LabsRange.allCases.filter { $0.rawValue >= LabsRange.standard.rawValue && $0 != .all }
        return candidates.first { valueBearing(windowed(rows, range: $0, now: now)).count >= 2 } ?? .all
    }

    /// Rows that carry a NUMERIC reading. Any value math / plot must run over
    /// this set, or a row without a number drags `min`/`mean`/`median` down and
    /// paints a misleading dip-to-zero — the same special case the FHIR exporter
    /// makes. The list views keep every row so the user still sees the reading
    /// exists; only the derivations exclude them.
    ///
    /// This now also excludes QUALITATIVE rows (`valueText` set,
    /// `value == nil`). "negativ" has no position on a numeric axis; before the
    /// `Double?` change such a row decoded to `0` and was plotted.
    static func valueBearing(_ rows: [LabResultDTO]) -> [LabResultDTO] {
        rows.filter { $0.value != nil }
    }

    /// The numeric readings of `rows`, absent + qualitative rows dropped.
    static func numericValues(_ rows: [LabResultDTO]) -> [Double] {
        rows.compactMap(\.value)
    }

    /// On-device `SeriesStats` (mean / min / max + count) over the rows' values.
    /// Returns `nil` for an empty set so the stats row self-suppresses. `stdDev`
    /// is computed for completeness though `StatsRow` only reads min/mean/max +
    /// the separately-supplied median. Mirrors the Insights server `SeriesStats`
    /// shape so the value-typed `StatsRow` can render it unchanged. `valueIsAbsent`
    /// rows are excluded so a phantom `0` never skews the stats.
    static func stats(for rows: [LabResultDTO]) -> SeriesStats? {
        let values = numericValues(rows)
        guard let min = values.min(), let max = values.max() else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return SeriesStats(mean: mean, min: min, max: max, stdDev: variance.squareRoot(), count: values.count)
    }

    /// The statistics the marker page shows: only from two numeric readings
    /// on, since one reading would print the same figure in every cell.
    static func pageStats(for rows: [LabResultDTO]) -> SeriesStats? {
        guard let stats = stats(for: rows), stats.count >= 2 else { return nil }
        return stats
    }

    /// Median over the rows' values — reuses the pure, `nonisolated`
    /// `ChartDetailStore.median(of:)` so the math is identical to the Insights
    /// page. `valueIsAbsent` rows are excluded so a phantom `0` never skews the
    /// median. `nil` for an empty set.
    static func median(for rows: [LabResultDTO]) -> Double? {
        ChartDetailStore.median(of: numericValues(rows))
    }

    /// The statistic cells of the detail page: Min, Ø, Max and, when there is
    /// one, the median, in the order of the reference metric page.
    static func statCells(stats: SeriesStats, median: Double?, unit: String) -> [HLStatCell] {
        func format(_ value: Double) -> String {
            HLValueFormat.number(value, fractionDigits: 0 ... 1)
        }
        var cells = [
            HLStatCell(label: String(localized: "Min"), value: format(stats.min), unit: unit),
            HLStatCell(label: String(localized: "chart.stat.mean"), value: format(stats.mean), unit: unit),
            HLStatCell(label: String(localized: "Max"), value: format(stats.max), unit: unit)
        ]
        if let median {
            cells.append(HLStatCell(label: String(localized: "chart.stat.median"), value: format(median), unit: unit))
        }
        return cells
    }

    /// The reference range as a fact ("10 to 50 U/l", "≥ 4.5"), `nil` without
    /// any bound. The unity "1" is never printed after a number.
    static func referenceText(low: Double?, high: Double?, unit: String) -> String? {
        func num(_ value: Double) -> String {
            HLValueFormat.number(value, fractionDigits: 0 ... 2)
        }
        let bare: String? = switch (low, high) {
        case let (low?, high?): HLNumberFormat.range(num(low), num(high))
        case let (low?, nil): "≥ \(num(low))"
        case let (nil, high?): "≤ \(num(high))"
        case (nil, nil): nil
        }
        guard let bare else { return nil }
        return LabUnit.appending(unit, to: bare)
    }

    /// How many readings the server judged inside their range, out of all it
    /// judged. Readings without a range do not count; `nil` when none was
    /// judged.
    static func inRangeShare(_ rows: [LabResultDTO]) -> (inRange: Int, judged: Int)? {
        let judged = rows.filter { $0.rangeStatus != .unknown }
        guard !judged.isEmpty else { return nil }
        return (judged.count(where: { $0.rangeStatus == .inRange }), judged.count)
    }
}
