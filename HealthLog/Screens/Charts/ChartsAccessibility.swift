import Accessibility
import Foundation

/// Builds `AXChartDescriptor`s for the Trends/Charts screen.
///
/// Lives in its own type so unit tests can drive descriptor construction without
/// instantiating the SwiftUI view. The descriptor is intentionally a value type and
/// pure function — re-built every render, no hidden state.
///
/// **Why this exists / what it fixes (UX audit C3 + C4):**
/// - **C3**: x-axis used to return empty strings, so VoiceOver read "(empty)" for every
///   tick. We now format each tick's `Date` with a localized formatter.
/// - **C4**: blood-pressure renders systolic + diastolic as two visible lines, but only
///   one was exposed accessibly. We now emit two `AXDataSeriesDescriptor`s for BP so
///   VoiceOver users can swipe between both series.
enum ChartsAccessibility {
    /// Cached formatter — `DateFormatter` allocation is non-trivial, and accessibility
    /// descriptors are rebuilt on every render. Locale is read from `Locale.autoupdatingCurrent`
    /// so OS language switches are respected without app restart.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("dMMM") // e.g. "9. Mai" (de), "May 9" (en)
        return f
    }()

    /// Builds a chart descriptor for a measurement series.
    ///
    /// - Parameters:
    ///   - series: the resolved data + stats from `ChartsStore`.
    ///   - kind: the metric the series belongs to — drives series naming + summary unit.
    /// - Returns: descriptor with a populated x-axis (dates) and one or two series
    ///   (two for blood pressure, one otherwise).
    static func makeDescriptor(for series: MeasurementSeries, kind: MetricKind) -> AXChartDescriptor {
        let points = series.points
        let xAxis = makeXAxis(for: points)
        let yAxis = makeYAxis(for: series, kind: kind)
        let dataSeries = makeSeries(for: series, kind: kind)

        return AXChartDescriptor(
            title: chartTitle(for: kind),
            summary: chartSummary(for: series.stats, kind: kind),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: dataSeries
        )
    }

    // MARK: - Axes

    private static func makeXAxis(for points: [SeriesPoint]) -> AXNumericDataAxisDescriptor {
        let upper = max(Double(points.count), 1) // empty series still needs a valid range
        return AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: 0 ... upper,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                // C3 fix: VoiceOver previously announced "(empty)" because the provider
                // returned "". Map the integer index back to the underlying Date and format
                // it for the user's current locale.
                let idx = Int(value.rounded())
                guard points.indices.contains(idx) else {
                    return ""
                }
                return dateFormatter.string(from: points[idx].at)
            }
        )
    }

    private static func makeYAxis(for series: MeasurementSeries, kind: MetricKind) -> AXNumericDataAxisDescriptor {
        // Guard against a degenerate min == max range (single value or all-equal points)
        // — `AXNumericDataAxisDescriptor.range` requires lower <= upper, so we widen by 1
        // when needed to keep the descriptor valid.
        let lower = series.stats.min
        let upper = series.stats.max > series.stats.min ? series.stats.max : series.stats.min + 1
        return AXNumericDataAxisDescriptor(
            title: kind.unit,
            range: lower ... upper,
            gridlinePositions: [],
            valueDescriptionProvider: { "\(Int($0))" }
        )
    }

    // MARK: - Series

    private static func makeSeries(
        for series: MeasurementSeries,
        kind: MetricKind
    ) -> [AXDataSeriesDescriptor] {
        let points = series.points
        let hasSecondary = points.contains(where: { $0.secondary != nil })

        if kind == .bloodPressure, hasSecondary {
            // C4 fix: expose BOTH systolic and diastolic as separate accessible series.
            // VoiceOver users can now swipe between the two with the rotor.
            let systolic = AXDataSeriesDescriptor(
                name: String(localized: "Systolic"),
                isContinuous: true,
                dataPoints: points.enumerated().map { idx, p in
                    AXDataPoint(x: Double(idx), y: p.value)
                }
            )
            let diastolic = AXDataSeriesDescriptor(
                name: String(localized: "Diastolic"),
                isContinuous: true,
                dataPoints: points.enumerated().compactMap { idx, p in
                    guard let secondary = p.secondary else { return nil }
                    return AXDataPoint(x: Double(idx), y: secondary)
                }
            )
            return [systolic, diastolic]
        }

        return [
            AXDataSeriesDescriptor(
                name: kind.displayName,
                isContinuous: true,
                dataPoints: points.enumerated().map { idx, p in
                    AXDataPoint(x: Double(idx), y: p.value)
                }
            )
        ]
    }

    // MARK: - Title + summary

    private static func chartTitle(for kind: MetricKind) -> String {
        // "<Metric> Verlauf" — single localizable key with placeholder so EN can flip the
        // word order ("<Metric> trend" / "Trend von <Metric>").
        String(localized: "\(kind.displayName) trend")
    }

    private static func chartSummary(for stats: SeriesStats, kind: MetricKind) -> String {
        let mean = Int(stats.mean.rounded())
        let lo = Int(stats.min)
        let hi = Int(stats.max)
        let unit = kind.unit
        return String(
            localized: "Mean \(mean) \(unit), min \(lo), max \(hi)"
        )
    }

    // MARK: - Selected-point announcement (chart detail screen, A3 §5.2)

    /// Builds the VoiceOver announcement string for a selected chart point.
    /// Posted via `UIAccessibility.post(notification: .announcement, ...)` from
    /// `ChartDetailScreen` whenever `selectedDate` changes AND VoiceOver is
    /// active. Sighted users get the visible callout; VO users get the same
    /// information through the announcement channel (`chartXSelection` is
    /// touch-only and not driven via the rotor).
    ///
    /// - Parameters:
    ///   - point: the data point currently under the selection cursor.
    ///   - kind: drives unit + formatting (BP renders as "128 über 82 mmHg").
    /// - Returns: a short, naturally readable phrase. Locale-aware via
    ///   `Date.formatted(...)` and `String(localized:)`.
    static func selectedPointAnnouncement(
        point: SeriesPoint,
        kind: MetricKind
    ) -> String {
        let dateString = point.at.formatted(
            .dateTime.weekday(.wide).day().month().hour().minute()
        )
        let valueString: String = if let secondary = point.secondary {
            // BP reads naturally — "128 über 82" is what a clinician would say.
            String(localized: "\(Int(point.value.rounded())) over \(Int(secondary.rounded()))")
        } else {
            point.value.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        return String(
            localized: "\(dateString): \(valueString) \(kind.unit)"
        )
    }
}
