import SwiftUI

/// The head of the metric chart: the period the chart and the key figures
/// above it cover ("17. Okt. bis 17. Nov."), one quiet line where the period
/// choice stood before it moved into the floating bar. The page's large
/// figure is the latest reading above; the mean is a key figure tile, so the
/// head does not repeat it.
struct MetricPeriodSummary: View {
    let summary: Model

    /// The values of the period, resolved without a view so a test can pin
    /// them. The mean stays for the spoken summary of the chart.
    struct Model: Equatable {
        /// The mean, formatted ("122/78", "72,4", "7 Std. 12 Min.").
        let value: String
        /// The unit beside it, empty for a duration.
        let unit: String
        /// "17. Okt. bis 17. Nov."
        let period: String
    }

    var body: some View {
        Text(verbatim: summary.period)
            .hlText(.note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(verbatim: spoken))
            .accessibilityIdentifier("chart.card.periodSummary")
    }

    /// "17. Okt. bis 17. Nov., Ø 122/78 mmHg".
    private var spoken: String {
        let mean = [String(localized: "chart.stat.mean"), summary.value, summary.unit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(summary.period), \(mean)"
    }
}

extension MetricPeriodSummary.Model {
    /// The summary of `store`'s period, or `nil` when the period has no mean
    /// worth a headline: no statistics, or an event count whose mean says
    /// nothing.
    @MainActor
    static func resolve(store: ChartDetailStore, units settingsUnits: UnitPreferences, now: Date = .now) -> Self? {
        guard let stats = store.stats, !store.kind.suppressesAggregateStats else { return nil }
        let units = store.effectiveUnits(settingsUnits)
        let dates = store.chartPoints.map(\.at)
        guard let domain = MetricChartScale.xDomain(for: store.range, dates: dates, now: now)
            ?? (dates.isEmpty ? nil : MetricChartScale.dataDomain(dates)) else { return nil }
        return Self(
            value: value(mean: stats.mean, diastolicMean: store.diastolicStats?.mean, kind: store.kind, units: units),
            unit: MetricDurationFormat.unit(store.displayUnit(units: units), kind: store.kind),
            period: period(domain)
        )
    }

    /// The mean as the page writes a value of `kind`: a pressure pair, a
    /// duration in hours and minutes, else the number in the account's unit.
    static func value(mean: Double, diastolicMean: Double?, kind: MetricKind, units: UnitPreferences) -> String {
        if let duration = MetricDurationFormat.text(mean, kind: kind) {
            return duration
        }
        if kind == .bloodPressure, let diastolicMean {
            return MetricValueFormatter.formatBloodPressure(systolic: mean, diastolic: diastolicMean, units: units)
        }
        return MetricValueFormatter.formatScalar(mean, kind: kind, units: units, glucose: .seriesPreConvertedGlucose)
    }

    /// "17. Okt. bis 17. Nov.": day and short month, the year only when the
    /// period does not end in the current year or spans two.
    static func period(_ domain: ClosedRange<Date>, calendar: Calendar = .current, now: Date = .now) -> String {
        let sameYear = calendar.component(.year, from: domain.lowerBound) == calendar.component(.year, from: domain.upperBound)
            && calendar.component(.year, from: domain.upperBound) == calendar.component(.year, from: now)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year()
        let start = domain.lowerBound.formatted(style)
        let end = domain.upperBound.formatted(style)
        return String(localized: "chart.summary.period \(start) \(end)")
    }
}
