import Charts
import SwiftUI

/// **CU-30 / C5 — "Wie sonst um diese Zeit".** Today's cumulative standing for
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
/// ## One line per figure (1.4 B2)
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

    /// The block's PLACEMENT gate, pure logic so the wiring on
    /// ``InsightsMetricScreen`` is testable without a view host.
    ///
    /// Two load-bearing conditions: the page's metric must be one the server
    /// actually baselines (no other metric page may fire the read), and the
    /// value is pure server compute — in standalone / no-server there is
    /// nothing to ask for, so the block must not exist rather than sit empty.
    nonisolated static func supportedType(
        for kind: MetricKind,
        canShowCloudInsights: Bool
    ) -> SameTimeBaselineType? {
        guard canShowCloudInsights else { return nil }
        return SameTimeBaselineType.allCases.first { $0.metricKind == kind }
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

    private func card(asOfHour: Int?, @ViewBuilder content: () -> some View) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    Text("insights.sameTimeBaseline.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if let asOfHour {
                        // The last full hour the comparison stands at.
                        Text("insights.sameTimeBaseline.asOf \(asOfHour)")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize()
                            .accessibilityIdentifier("insights.sameTimeBaseline.asOf")
                    }
                }
                content()
            }
        }
        .accessibilityIdentifier("insights.sameTimeBaseline")
    }

    // MARK: - The `ok` arm

    @ViewBuilder
    private func okContent(_ baseline: SameTimeBaseline) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.lg) {
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
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
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
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Text(verbatim: unit.isEmpty ? number(value) : "\(number(value)) \(unit)")
                .font(.hlMetric(.title2))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
            if let range {
                Text("insights.sameTimeBaseline.range \(number(range.low)) \(number(range.high))")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
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
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
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
                        x: .value("Hour", point.hour),
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
                        x: .value("Hour", point.hour),
                        y: .value("Value", point.today),
                        series: .value("Series", "today")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                    .foregroundStyle(HLChartTints.series)
                }
            }
            .chartXScale(domain: 0 ... max(baseline.asOfHour, 1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(verbatim: "\(hour)")
                                .font(.hlCaption2)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(verbatim: number(raw))
                                .font(.hlCaption2)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                }
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
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.gate")
    }

    // MARK: - Formatting

    /// Locale-aware rendering of a server figure. The server does NOT round
    /// `todayValue` / `typicalValue` (a median of integers can be `x.5`), so a
    /// half step is shown as a half step rather than being quietly re-rounded.
    private func number(_ value: Double) -> String {
        let isWhole = value == value.rounded()
        return HLNumberFormat.decimal(value, fractionDigits: isWhole ? 0 : 1)
    }
}
