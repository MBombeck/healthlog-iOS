import Charts
import SwiftUI

/// **"Wie sonst um diese Zeit".** Today's cumulative standing for
/// one of the four cumulative types against the operator's own typical standing
/// at the SAME hour of day (server v1.34.0, `SAME_TIME_BASELINE`).
///
/// ## Why the surface exists
///
/// A cumulative metric has no meaningful "latest reading". Four thousand steps
/// is a good day at nine in the morning and a poor one at ten at night. The
/// comparison that carries information is against the same hour of the usual
/// day — which is exactly what the server computes.
///
/// ## Nothing is recomputed, and nothing is projected
///
/// Every figure on this card is server-computed and inspectable: today's total,
/// the typical total, the band edges, the signed delta, the percentage, and
/// both curves. iOS re-derives none of them, and **derives no end-of-day
/// forecast** — the server deliberately ships none, because extrapolating from
/// a partial day would be a guess, and this card exists to replace guessing.
/// The only client-side arithmetic in this file is chart-axis padding.
///
/// ## The gated arms are the normal case
///
/// `learning_usual_day` is the standing state of the first two weeks and shows
/// the "N von 14" counter, one line in the card. Every other gate
/// (`no_intraday_today`, a PERMANENT state for accounts whose activity arrives
/// as a daily total, `day_too_young`, `unsupported_baseline_type`, anything
/// this build does not model) has nothing to compare and no action, so the
/// card is not there at all (1.4 B2, R2 rule 4: empty cards disappear). None
/// of them is an error.
///
/// ## One line per figure
///
/// The hour sits in the title row, the usual range under the "usual" figure.
/// What the dashed curve is and what the comparison rests on are in the
/// page's info sheet (`InsightsMetricInfo`), not in six lines around two
/// numbers.
struct SameTimeBaselineBlock: View {
    /// The cumulative type this instance baselines. Steps is the server's own
    /// default and the only type that drives a digest rail card.
    var type: SameTimeBaselineType = .default

    @Environment(DerivedInsightsStore.self) private var store
    /// The hour the curve chart is scrubbed to.
    @State private var selectedDate: Date?

    /// The block's PLACEMENT gate, pure logic so the wiring on
    /// ``InsightsMetricScreen`` is testable without a view host.
    ///
    /// The page's metric must be one the server actually baselines (no other
    /// metric page may fire the read).
    nonisolated static func supportedType(for kind: MetricKind) -> SameTimeBaselineType? {
        SameTimeBaselineType.allCases.first { $0.metricKind == kind }
    }

    var body: some View {
        Group {
            if let baseline = store.sameTimeBaseline?.sameTimeBaseline {
                card(asOfHour: baseline.asOfHour) { okContent(baseline) }
            } else if case let .learningUsualDay(historyDays) = store.sameTimeBaseline?.sameTimeBaselineGate {
                card(asOfHour: nil) { learningContent(historyDays) }
            }
            // Nothing settled yet, a gate with nothing to compare, or a
            // 404/422/transport miss: the block stays absent rather than
            // showing a dead shell.
        }
        .task { await store.loadSameTimeBaseline(type: type) }
    }

    // MARK: - Shell

    /// The card head carries the title and the hour the comparison stands at.
    private func card(asOfHour: Int?, @ViewBuilder content: () -> some View) -> some View {
        HLCard("insights.sameTimeBaseline.title", trailing: {
            if let asOfHour {
                // The last full hour the comparison stands at.
                Text("insights.sameTimeBaseline.asOf \(asOfHour)")
                    .hlText(.rowSubtitle)
                    .fixedSize()
                    .accessibilityIdentifier("insights.sameTimeBaseline.asOf")
            }
        }, content: {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                content()
            }
        })
        .accessibilityIdentifier("insights.sameTimeBaseline")
    }

    // MARK: - The `ok` arm

    @ViewBuilder
    private func okContent(_ baseline: SameTimeBaseline) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLLayout.cardGap) {
            figure(
                label: "insights.sameTimeBaseline.today",
                value: baseline.todayValue,
                unit: baseline.displayUnit
            )
            figure(
                label: "insights.sameTimeBaseline.typical",
                value: baseline.typicalValue,
                unit: baseline.displayUnit,
                range: (baseline.typicalLow, baseline.typicalHigh)
            )
        }

        Text(bandLine(baseline))
            .hlText(.prose)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.band")

        percentLine(baseline)

        curveChart(baseline)
    }

    /// One figure; the "usual" one carries its usual range as its caption.
    private func figure(
        label: LocalizedStringKey,
        value: Double,
        unit: String,
        range: (low: Double, high: Double)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(label)
                .hlText(.rowSubtitle)
            // A grid cell: the compact value size, half steps kept.
            HLValueText(value, unit: HLUnit(symbol: unit), size: .compact, fractionDigits: Self.fractionDigits(value))
            if let range {
                Text("insights.sameTimeBaseline.range \(number(range.low)) \(number(range.high))")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where today's total stands. The server owns the verdict (``band``); this
    /// only picks the matching sentence and fills in the server's own signed
    /// delta as a magnitude.
    private func bandLine(_ baseline: SameTimeBaseline) -> LocalizedStringKey {
        let magnitude = number(abs(baseline.delta))
        switch baseline.band {
        case .above: return "insights.sameTimeBaseline.band.above \(magnitude)"
        case .below: return "insights.sameTimeBaseline.band.below \(magnitude)"
        case .within: return "insights.sameTimeBaseline.band.within"
        }
    }

    /// The percentage, when there is one.
    ///
    /// `percentOfTypical == nil` sits on a perfectly healthy `ok` arm: it means
    /// the typical total at this hour is zero (the normal state at 05:00), an
    /// undefined ratio. It is NOT a hundred percent, NOT missing data, and NOT
    /// a reason to suppress the rest of the card; the line is simply left out
    /// (1.4 B2: no sentence explaining why a number is missing).
    @ViewBuilder
    private func percentLine(_ baseline: SameTimeBaseline) -> some View {
        if let percent = baseline.percentOfTypical {
            Text("insights.sameTimeBaseline.percent \(HLNumberFormat.percent(percent))")
                .hlText(.rowSubtitle)
                .accessibilityIdentifier("insights.sameTimeBaseline.percent")
        }
    }

    // MARK: - Curves

    /// The two index-aligned cumulative curves, hour `0 … asOfHour`. Today is
    /// the solid series, the usual day the dashed reference — a median across
    /// the window, never a single real day, which is what the caption says.
    ///
    /// Drawn only when the server's own length invariant holds
    /// (``SameTimeBaseline/curvesAreAligned``). A payload that violates it
    /// keeps every number on the card and silently drops the chart rather than
    /// drawing a misaligned comparison.
    @ViewBuilder
    private func curveChart(_ baseline: SameTimeBaseline) -> some View {
        let points = baseline.curvePoints
        if !points.isEmpty {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Hour", point.scrubDate),
                        y: .value("Value", point.typical),
                        series: .value("Series", "typical")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.thresholdWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
                    .foregroundStyle(HLText.secondary.opacity(0.7))
                }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Hour", point.scrubDate),
                        y: .value("Value", point.today),
                        series: .value("Series", "today")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                    .foregroundStyle(HLChartTints.series)
                }
                HLChartScrubber.marks(
                    selectedDate: selectedDate,
                    in: points,
                    date: \.scrubDate,
                    value: \.today
                ) { point in
                    HLScrubCallout(
                        title: Self.hourLabel(point.hour),
                        value: number(point.today),
                        unit: baseline.displayUnit
                    )
                }
            }
            .chartXScale(domain: Self.date(forHour: 0) ... Self.date(forHour: max(baseline.asOfHour, 1)))
            .chartXAxis { Self.hourAxis }
            // Values on the leading edge, like every chart with axes.
            .hlChartValueAxis(label: Self.formatted)
            .hlChartScrub($selectedDate) { date in
                scrubAnnouncement(at: date, in: points, unit: baseline.displayUnit)
            }
            .frame(height: HLChartStyle.heightRegular)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("insights.sameTimeBaseline.title"))
            .accessibilityValue(Text(chartSummary(baseline)))
            .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor(baseline, points: points)))
            .accessibilityIdentifier("insights.sameTimeBaseline.chart")

            Text("insights.sameTimeBaseline.legend")
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chartDescriptor(
        _ baseline: SameTimeBaseline,
        points: [SameTimeBaseline.Point]
    ) -> AXChartDescriptor {
        HLChartAX.singleSeries(
            title: String(localized: "insights.sameTimeBaseline.title"),
            summary: chartSummary(baseline),
            xAxisTitle: String(localized: "insights.sameTimeBaseline.axis.hour"),
            yAxisTitle: String(localized: "insights.sameTimeBaseline.axis.total"),
            seriesName: String(localized: "insights.sameTimeBaseline.today"),
            points: points.map { (x: Double($0.hour), y: $0.today, xLabel: "\($0.hour)") },
            yValueLabel: { number($0) }
        )
    }

    /// A spoken summary built from the SERVER's figures only — same factual,
    /// non-diagnostic framing the visible card carries.
    private func chartSummary(_ baseline: SameTimeBaseline) -> String {
        String(
            localized: "insights.sameTimeBaseline.a11y \(baseline.asOfHour) \(number(baseline.todayValue)) \(number(baseline.typicalValue))"
        )
    }

    // MARK: - The learning arm

    /// The normal state of the first two weeks: say how far along it is
    /// instead of implying something is broken. One calm line, no warning
    /// tint, no retry.
    private func learningContent(_ historyDays: Int) -> some View {
        Text("insights.sameTimeBaseline.gate.learning \(historyDays) \(SameTimeBaselineMetric.requiredHistoryDays)")
            .hlText(.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.gate")
    }

    // MARK: - Hour axis

    /// The hours under the curves, in caption type.
    static var hourAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(verbatim: "\(hour(of: date))")
                        .hlText(.rowSubtitle)
                }
            }
        }
    }

    /// An hour of the day on the anchor day the intraday pulse chart uses,
    /// so this chart scrubs like every other time series.
    nonisolated static func date(forHour hour: Int) -> Date {
        IntradayPulseChartView.date(forMinute: hour * 60)
    }

    nonisolated static func hour(of date: Date) -> Int {
        IntradayPulseChartView.minute(of: date) / 60
    }

    /// "09:00" for the scrub callout.
    nonisolated static func hourLabel(_ hour: Int) -> String {
        IntradayPulseMath.minuteLabel(hour * 60)
    }

    /// What VoiceOver reads when the scrub snaps: hour, today's total, unit.
    private func scrubAnnouncement(at date: Date, in points: [SameTimeBaseline.Point], unit: String) -> String? {
        guard let point = HLChartScrubber.nearest(to: date, in: points, date: \.scrubDate) else { return nil }
        return HLScrubCallout.spokenText(
            title: Self.hourLabel(point.hour),
            value: number(point.today),
            unit: unit,
            marksRecord: false
        )
    }

    // MARK: - Formatting

    /// A whole figure without decimals, a half step with one.
    nonisolated static func fractionDigits(_ value: Double) -> ClosedRange<Int> {
        value == value.rounded() ? 0 ... 0 : 1 ... 1
    }

    /// Locale-aware rendering of a server figure. The server does NOT round
    /// `todayValue` / `typicalValue` (a median of integers can be `x.5`), so a
    /// half step is shown as a half step rather than being quietly re-rounded.
    private func number(_ value: Double) -> String {
        Self.formatted(value)
    }

    /// The same for the value axis, which takes a plain function.
    nonisolated static func formatted(_ value: Double) -> String {
        let isWhole = value == value.rounded()
        return HLNumberFormat.decimal(value, fractionDigits: isWhole ? 0 : 1)
    }
}

extension SameTimeBaseline.Point {
    /// The hour on the chart's time axis.
    var scrubDate: Date {
        SameTimeBaselineBlock.date(forHour: hour)
    }
}
