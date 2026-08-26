import Foundation

/// Pure value helpers backing the custom-metric detail page. Everything here is
/// a derivation of the already-loaded `CustomMetricsStore.entries(for:)` — no new
/// server endpoint. Mirrors ``BiomarkerSeries`` so the two detail pages compute
/// their stats, median and windows identically.
enum CustomMetricSeries {
    /// Time-window selector, reusing the labs vocabulary (Tag / Woche / Monat /
    /// Jahr / Alle) so the muscle memory carries across detail pages.
    /// `rawValue` is the window size in days and doubles as the cutoff.
    enum Range: Int, CaseIterable, Identifiable, Hashable {
        case day = 1
        case week = 7
        case month = 30
        case year = 365
        /// "Alle Daten" — wide enough to cover any realistic history.
        case all = 3650

        var id: Int {
            rawValue
        }
    }

    /// Filter `entries` to those measured within `range` of `now`. `.all` is a
    /// pass-through. An entry whose `measuredAt` fails to parse is KEPT — we
    /// never silently drop a logged value because of a malformed wire timestamp
    /// (same rule `BiomarkerSeries.windowed` applies).
    static func windowed(
        _ entries: [CustomMetricEntryDTO],
        range: Range,
        now: Date = .now
    ) -> [CustomMetricEntryDTO] {
        guard range != .all else { return entries }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: now) else {
            return entries
        }
        return entries.filter { entry in
            guard let date = LabsDateFormat.parse(entry.measuredAt) else { return true }
            return date >= cutoff
        }
    }

    /// Entries carrying a NUMERIC reading. Every derivation and the plot must run
    /// over this set — an absent value would drag the stats down and paint a
    /// phantom dip to zero. The list views keep every row so the user still sees
    /// the entry exists.
    static func valueBearing(_ entries: [CustomMetricEntryDTO]) -> [CustomMetricEntryDTO] {
        entries.filter { $0.value != nil }
    }

    /// The numeric readings, absent rows dropped.
    static func numericValues(_ entries: [CustomMetricEntryDTO]) -> [Double] {
        entries.compactMap(\.value)
    }

    /// On-device `SeriesStats` (mean / min / max / stdDev + count). `nil` for an
    /// empty set so the stat strip self-suppresses.
    static func stats(for entries: [CustomMetricEntryDTO]) -> SeriesStats? {
        let values = numericValues(entries)
        guard let min = values.min(), let max = values.max() else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return SeriesStats(mean: mean, min: min, max: max, stdDev: variance.squareRoot(), count: values.count)
    }

    /// Median — reuses the pure, `nonisolated` `ChartDetailStore.median(of:)` so
    /// the math is identical to the Insights and labs pages. `nil` when empty.
    static func median(for entries: [CustomMetricEntryDTO]) -> Double? {
        ChartDetailStore.median(of: numericValues(entries))
    }

    /// Chart points for the generic ``BiomarkerChart`` initialiser. Absent
    /// readings and unparseable timestamps are dropped — a point needs both
    /// coordinates to be plottable at all.
    static func chartPoints(_ entries: [CustomMetricEntryDTO]) -> [BiomarkerChart.DatedValue] {
        entries.compactMap { entry in
            guard let date = LabsDateFormat.parse(entry.measuredAt), let value = entry.value else { return nil }
            return BiomarkerChart.DatedValue(id: entry.id, date: date, value: value)
        }
    }

    /// How many of `entries` sit inside the metric's target window. `nil` when
    /// the metric declares no band (nothing to report) or no entry carries a
    /// number. Presented as a calm "N von M im Zielbereich" caption — a count,
    /// never a score or a grade.
    static func inBandCount(
        _ entries: [CustomMetricEntryDTO],
        metric: CustomMetricDTO
    ) -> (inBand: Int, total: Int)? {
        guard metric.hasTargetBand else { return nil }
        let numeric = valueBearing(entries)
        guard !numeric.isEmpty else { return nil }
        let inBand = numeric.filter { metric.bandStatus(for: $0.value) == .inBand }.count
        return (inBand: inBand, total: numeric.count)
    }
}

// MARK: - HLRangeOption conformance

/// Adopt the canonical `HLRangeOption` so the custom-metric detail page drives
/// the same `HLFloatingPeriodControl` every other chart uses. Reuses the labs
/// range labels — the vocabulary is identical and duplicating five string keys
/// would only invite drift.
extension CustomMetricSeries.Range: HLRangeOption {
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
