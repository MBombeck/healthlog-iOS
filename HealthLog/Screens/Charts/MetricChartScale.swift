import Charts
import SwiftUI

/// The scales of the metric chart: the date axis spans the chosen period, the
/// value axis ends on a grid line with one step of room above the highest
/// value.
///
/// Pure functions, so a test can pin the domains without drawing a chart.
enum MetricChartScale {
    // MARK: - Date axis

    /// The date domain of a chart for `range`: from the first day of the
    /// period to `now`. The axis follows the choice, not the data, so a page
    /// with readings on three days still shows the whole month under "M".
    /// "All" has no lower edge and spans the readings up to `now`. A reading
    /// after `now` widens the domain, so it is never cut off.
    static func xDomain(
        for range: ChartDetailStore.Range,
        dates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        let upper = max(now, dates.max() ?? now)
        let lower: Date? = if range == .all {
            dates.min()
        } else {
            HLTimeRange(days: range.rawValue)?.start(endingAt: now, calendar: calendar)
        }
        guard let lower, lower < upper else { return nil }
        return min(lower, dates.min() ?? lower) ... upper
    }

    /// The span of the readings themselves, at least a day wide; the
    /// fallback when the period gives no domain.
    static func dataDomain(_ dates: [Date]) -> ClosedRange<Date> {
        let first = dates.min() ?? .now
        let last = max(dates.max() ?? first, first.addingTimeInterval(24 * 3600))
        return first ... last
    }

    // MARK: - Value axis

    /// The value domain of a linear chart: both ends on a step of the grid,
    /// one whole step of room above the highest value, so no line runs over
    /// the top grid line. A percentage never reads past 100.
    static func yDomain(values: [Double], capsAtHundred: Bool = false) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return 0 ... 1 }
        let step = gridStep(span: high - low, magnitude: max(abs(high), abs(low)))
        var lower = (low / step).rounded(.down) * step
        var upper = ((high / step).rounded(.down) + 1) * step
        if low >= 0 { lower = max(0, lower) }
        if capsAtHundred, high <= 100 { upper = min(upper, 100) }
        return lower < upper ? lower ... upper : lower ... lower + step
    }

    /// The value domain of a metric chart, the one rule for the card and
    /// the full screen: log when chosen (every reference line on screen),
    /// whole hours over at least three for a duration, otherwise
    /// grid-aligned with a step of room and at least the metric's span.
    static func valueDomain(
        points: [SeriesPoint],
        references: [SeriesReferenceLine],
        kind: MetricKind,
        unit: String,
        useLog: Bool
    ) -> ClosedRange<Double> {
        if useLog {
            return MetricChartMath.logDomain(for: points, including: references)
        }
        if MetricDurationFormat.isDuration(kind) {
            return MetricDurationFormat.hourDomain(values: points.map(\.value))
        }
        let caps = capsAtHundred(unit: unit)
        return widened(
            yDomain(
                values: points.flatMap { [$0.value] + ($0.secondary.map { [$0] } ?? []) } + references.map(\.value),
                capsAtHundred: caps
            ),
            toSpan: minimumSpan(for: kind, unit: unit),
            capsAtHundred: caps
        )
    }

    /// The least height of the value axis for `kind`, in the series' own
    /// unit, so a calm series stays calm instead of filling the plot: a
    /// weight that moves 1.6 kg in a month is not drawn like an alarm.
    /// `nil` keeps the axis on the data alone.
    static func minimumSpan(for kind: MetricKind, unit: String) -> Double? {
        switch kind {
        // Only in kilograms: a converted pound series keeps its own fit.
        case .weight: unit.trimmingCharacters(in: .whitespaces) == "kg" ? 4 : nil
        case .pulse, .restingHeartRate, .walkingHeartRate, .averageHeartRate: 20
        case .spo2: 10
        default: nil
        }
    }

    /// `domain` widened to at least `span` around its middle, never below
    /// zero and, for a percentage, never above 100.
    static func widened(_ domain: ClosedRange<Double>, toSpan span: Double?, capsAtHundred: Bool = false) -> ClosedRange<Double> {
        guard let span, span > 0, domain.upperBound - domain.lowerBound < span else { return domain }
        let middle = (domain.lowerBound + domain.upperBound) / 2
        var lower = middle - span / 2
        var upper = middle + span / 2
        if capsAtHundred, upper > 100 {
            lower -= upper - 100
            upper = 100
        }
        if domain.lowerBound >= 0, lower < 0 {
            upper -= lower
            lower = 0
        }
        return snapped(lower ... upper, step: gridStep(span: span, magnitude: max(abs(lower), abs(upper))), capsAtHundred: capsAtHundred)
    }

    /// `domain` with both ends on a step of the grid, so the top and the
    /// bottom of the axis carry a tick and no gap opens under the unit.
    static func snapped(_ domain: ClosedRange<Double>, step: Double, capsAtHundred: Bool = false) -> ClosedRange<Double> {
        guard step > 0, step.isFinite else { return domain }
        var lower = (domain.lowerBound / step).rounded(.down) * step
        var upper = (domain.upperBound / step).rounded(.up) * step
        if domain.lowerBound >= 0 { lower = max(0, lower) }
        if capsAtHundred, domain.upperBound <= 100 { upper = min(upper, 100) }
        return lower < upper ? lower ... upper : domain
    }

    /// A step of 1, 2, 2.5 or 5 times a power of ten that divides the span
    /// into about four parts. A flat series takes a step of a twentieth of
    /// its value (at least the smallest step), so the line sits in the plot.
    static func gridStep(span: Double, magnitude: Double) -> Double {
        let raw = span > 0 ? span / 4 : max(magnitude / 20, 0.1)
        let power = pow(10, log10(raw).rounded(.down))
        let fraction = raw / power
        let nice: Double = switch fraction {
        case ...1: 1
        case ...2: 2
        case ...2.5: 2.5
        case ...5: 5
        default: 10
        }
        return nice * power
    }

    /// The tick step of a value axis on `domain`: the smallest step of 1, 2,
    /// 2.5 or 5 times a power of ten that puts a tick on both ends and at
    /// most six parts between them, so the top tick stands at the top of
    /// the plot, right under the unit. `nil` when no such step exists.
    static func tickStep(for domain: ClosedRange<Double>, maximumParts: Int = 6) -> Double? {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite else { return nil }
        let start = pow(10, log10(span / Double(maximumParts)).rounded(.down))
        for power in [start, start * 10] {
            for factor in [1.0, 2, 2.5, 5] {
                let step = factor * power
                let parts = span / step
                guard parts <= Double(maximumParts) + 1e-9 else { continue }
                if isMultiple(domain.lowerBound, of: step), isMultiple(domain.upperBound, of: step) {
                    return step
                }
            }
        }
        return nil
    }

    /// The value ticks of a metric chart: whole hours for a duration, the
    /// grid step of a linear axis, the system's own on a log axis or at the
    /// accessibility sizes (fewer, larger labels).
    static func axisValues(
        domain: ClosedRange<Double>,
        kind: MetricKind,
        useLog: Bool,
        isAccessibilitySize: Bool
    ) -> AxisMarkValues? {
        if MetricDurationFormat.isDuration(kind) { return .stride(by: 1) }
        guard !useLog, !isAccessibilitySize, let step = tickStep(for: domain) else { return nil }
        return .stride(by: step)
    }

    private static func isMultiple(_ value: Double, of step: Double) -> Bool {
        let ratio = value / step
        return abs(ratio - ratio.rounded()) < 1e-6
    }

    /// Whether the value axis reads in percent and stops at 100.
    static func capsAtHundred(unit: String) -> Bool {
        unit.trimmingCharacters(in: .whitespaces) == "%"
    }
}

// MARK: - Durations

/// Sleep is a length of time. The series carries hours as a decimal; the page
/// shows them the way the start page does ("7 Std. 12 Min.") and labels its
/// axis with the hour word of the interface language.
enum MetricDurationFormat {
    /// The kinds whose value is a length of time in hours.
    static func isDuration(_ kind: MetricKind) -> Bool {
        kind == .sleep
    }

    /// Hours as hours and minutes.
    static func text(hours: Double, locale: Locale = .current) -> String {
        HLTimeFormat.duration(hours * 3600, locale: locale)
    }

    /// Hours on a clock face, "6:47": the short form for a statistic cell and
    /// an axis tick, where "6 Std. 47 Min." does not fit. The unit stands
    /// beside it (``axisUnit(_:kind:)``).
    static func clock(hours: Double) -> String {
        let minutes = Int((max(0, hours) * 60).rounded())
        return Duration.seconds(minutes * 60).formatted(.time(pattern: .hourMinute))
    }

    /// The short form for `kind`, or `nil` when the kind is not a duration.
    static func clock(_ value: Double, kind: MetricKind) -> String? {
        isDuration(kind) ? clock(hours: value) : nil
    }

    /// A value of `kind` as the page shows it, or `nil` when the kind is not
    /// a duration and keeps its number and unit.
    static func text(_ value: Double, kind: MetricKind) -> String? {
        isDuration(kind) ? text(hours: value) : nil
    }

    /// The unit next to a value of `kind`: none for a duration, whose text
    /// names its units itself.
    static func unit(_ unit: String, kind: MetricKind) -> String {
        isDuration(kind) ? "" : unit
    }

    /// Whether the unit of `kind` names a scale ("von 21"), not a measure: it
    /// belongs to the page's main value, not to every axis tick and cell.
    static func isScale(_ kind: MetricKind) -> Bool {
        kind.unitFamily == .strainScale
    }

    /// The unit above the value axis: the hour word for a duration, nothing
    /// for a scale.
    static func axisUnit(_ unit: String, kind: MetricKind) -> String {
        if isDuration(kind) { return String(localized: "unit.hours.short") }
        return isScale(kind) ? "" : unit
    }

    /// Hours in a narrow table cell in the words of the page's head,
    /// "7 Std." over "13 Min.": one way to write a length of time on the
    /// page, stacked because a quarter of the row holds one part per line.
    static func cell(hours: Double, locale: Locale = .current) -> String {
        HLTimeFormat.durationParts(hours * 3600, locale: locale).joined(separator: "\n")
    }

    /// The cell form for `kind`, or `nil` when the kind is not a duration.
    static func cell(_ value: Double, kind: MetricKind) -> String? {
        isDuration(kind) ? cell(hours: value) : nil
    }

    /// The unit of a statistic cell: none for a duration, which names its
    /// units in the cell itself, and none for a scale.
    static func cellUnit(_ unit: String, kind: MetricKind) -> String {
        isDuration(kind) || isScale(kind) ? "" : unit
    }

    /// A tick of the duration axis: the whole hour, the hour word stands
    /// above the axis.
    static func axisLabel(hours: Double) -> String {
        HLValueFormat.number(hours.rounded(), fractionDigits: 0 ... 0)
    }

    /// The value axis of a duration in whole hours, at least
    /// ``minimumHourSpan`` wide around the values, so a calm month of sleep
    /// does not fill the height like an alarm.
    static func hourDomain(values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return 0 ... minimumHourSpan }
        var lower = low.rounded(.down)
        var upper = max(high.rounded(.up), lower + 1)
        let missing = minimumHourSpan - (upper - lower)
        if missing > 0 {
            lower -= (missing / 2).rounded(.down)
            upper = lower + max(upper - lower, minimumHourSpan)
        }
        if lower < 0 {
            upper -= lower
            lower = 0
        }
        return lower ... upper
    }

    /// The least height of the duration axis, in hours.
    static let minimumHourSpan: Double = 3
}

// MARK: - Chart height

/// How tall the metric chart stands. On the phone and in narrow windows the
/// fixed regular height; from the side-by-side width on the chart takes at
/// least two fifths of the visible page height, so a wide window shows the
/// course large instead of a third of empty page.
enum MetricChartHeight {
    /// The share of the visible height the chart takes on a wide window.
    static let wideShare: CGFloat = 0.4

    static func height(visibleHeight: CGFloat, width: CGFloat) -> CGFloat {
        guard width >= HLLayout.sideBySideMinimum - 2 * HLLayout.pageMargin, visibleHeight.isFinite else {
            return HLChartStyle.heightRegular
        }
        return max(HLChartStyle.heightRegular, (visibleHeight * wideShare).rounded())
    }
}
