import Foundation

/// v0154 LR-REDO — pure value helpers backing the Insights-class biomarker
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
    /// Time-window selector for the detail page — mirrors `ChartDetailStore.Range`
    /// vocabulary (Tag / Woche / Monat / Jahr) so the muscle memory carries over
    /// from the Insights metric page. `rawValue` is the window size in days and
    /// doubles as the `windowed(...)` cutoff. `.all` carries the full history span.
    enum LabsRange: Int, CaseIterable, Identifiable, Hashable {
        case day = 1
        case week = 7
        case month = 30
        case year = 365
        /// "Alle Daten" — a span wide enough to cover any realistic lab history
        /// (matches `ChartDetailStore.Range.all`).
        case all = 3650

        var id: Int {
            rawValue
        }
    }

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
            guard let date = LabsDateFormat.parse(row.takenAt) else { return true }
            return date >= cutoff
        }
    }

    /// Rows that carry a NUMERIC reading. Any value math / plot must run over
    /// this set, or a row without a number drags `min`/`mean`/`median` down and
    /// paints a misleading dip-to-zero — the same special case the FHIR exporter
    /// makes. The list views keep every row so the user still sees the reading
    /// exists; only the derivations exclude them.
    ///
    /// Item 1.5 — this now also excludes QUALITATIVE rows (`valueText` set,
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

    /// Median over the rows' values — reuses the pure, `nonisolated`
    /// `ChartDetailStore.median(of:)` so the math is identical to the Insights
    /// page. `valueIsAbsent` rows are excluded so a phantom `0` never skews the
    /// median. `nil` for an empty set.
    static func median(for rows: [LabResultDTO]) -> Double? {
        ChartDetailStore.median(of: numericValues(rows))
    }
}

// MARK: - HLRangeOption conformance

/// Adopt the canonical `HLRangeOption` so the labs detail page drives the same
/// `HLFloatingPeriodControl` every chart uses. Apple-Health single-letter
/// vocabulary (T / W / M / J) sourced from localized labels.
extension BiomarkerSeries.LabsRange: HLRangeOption {
    var label: String {
        switch self {
        case .day: String(localized: "labs.range.day.short")
        case .week: String(localized: "labs.range.week.short")
        case .month: String(localized: "labs.range.month.short")
        case .year: String(localized: "labs.range.year.short")
        case .all: String(localized: "labs.range.all.short")
        }
    }

    var rangeAccessibilityLabel: String {
        switch self {
        case .day: String(localized: "labs.range.day")
        case .week: String(localized: "labs.range.week")
        case .month: String(localized: "labs.range.month")
        case .year: String(localized: "labs.range.year")
        case .all: String(localized: "labs.range.all")
        }
    }
}
