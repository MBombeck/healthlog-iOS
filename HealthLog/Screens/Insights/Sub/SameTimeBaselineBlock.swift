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
/// the "N von 14" counter. `no_intraday_today` is a PERMANENT state for
/// accounts whose activity arrives as a daily total (Fitbit, Withings, Polar)
/// — honest absence, rendered as a plain sentence. `day_too_young` and
/// `unsupported_baseline_type` read equally calmly. **None of them renders as
/// an error**, none gets a warning tint, and none offers a retry.
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
                card { okContent(baseline) }
            } else if let gate = store.sameTimeBaseline?.sameTimeBaselineGate {
                card { gateContent(gate) }
            }
            // Nothing settled yet, or a 404/422/transport miss: the block stays
            // absent rather than showing a dead shell.
        }
        .task { await store.loadSameTimeBaseline(type: type) }
    }

    // MARK: - Shell

    private func card(@ViewBuilder content: () -> some View) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("insights.sameTimeBaseline.title")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
        .accessibilityIdentifier("insights.sameTimeBaseline")
    }

    // MARK: - The `ok` arm

    @ViewBuilder
    private func okContent(_ baseline: SameTimeBaseline) -> some View {
        Text("insights.sameTimeBaseline.asOf \(baseline.asOfHour)")
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.asOf")

        HStack(alignment: .firstTextBaseline, spacing: HLSpace.lg) {
            figure(
                label: "insights.sameTimeBaseline.today",
                value: baseline.todayValue,
                unit: baseline.displayUnit
            )
            figure(
                label: "insights.sameTimeBaseline.typical",
                value: baseline.typicalValue,
                unit: baseline.displayUnit
            )
        }

        Text(bandLine(baseline))
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.band")

        percentLine(baseline)

        Text("insights.sameTimeBaseline.range \(number(baseline.typicalLow)) \(number(baseline.typicalHigh))")
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        curveChart(baseline)

        Text("insights.sameTimeBaseline.basis \(baseline.baselineDays) \(baseline.windowDays)")
            .font(.hlCaption2)
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.sameTimeBaseline.basis")
    }

    private func figure(label: LocalizedStringKey, value: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Text(verbatim: unit.isEmpty ? number(value) : "\(number(value)) \(unit)")
                .font(.hlMetric(.title2))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
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

    /// The percentage — or the honest note that a ratio is undefined right now.
    ///
    /// `percentOfTypical == nil` sits on a perfectly healthy `ok` arm: it means
    /// the typical total at this hour is zero (the normal state at 05:00), an
    /// undefined ratio. It is NOT a hundred percent, NOT missing data, and NOT
    /// a reason to suppress the rest of the card.
    @ViewBuilder
    private func percentLine(_ baseline: SameTimeBaseline) -> some View {
        if let percent = baseline.percentOfTypical {
            Text("insights.sameTimeBaseline.percent \(HLNumberFormat.percent(percent))")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .accessibilityIdentifier("insights.sameTimeBaseline.percent")
        } else {
            Text("insights.sameTimeBaseline.percent.undefined")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.sameTimeBaseline.percent.undefined")
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
            .frame(height: Self.chartHeight)
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

    // MARK: - The gated arms

    /// Every gated arm renders as one calm sentence in the SAME card, with no
    /// warning tint and no retry affordance. Two of them are long-lived states
    /// of a perfectly healthy account; treating them as failures would be a
    /// lie about the operator's data.
    private func gateContent(_ gate: SameTimeBaselineGate) -> some View {
        Group {
            switch gate {
            case let .learningUsualDay(historyDays):
                // The normal state of the first two weeks — say how far along
                // it is instead of implying something is broken.
                Text("insights.sameTimeBaseline.gate.learning \(historyDays) \(SameTimeBaselineMetric.requiredHistoryDays)")
            case .noIntradayToday:
                // A PERMANENT state for daily-total providers. Honest absence.
                Text("insights.sameTimeBaseline.gate.noIntraday")
            case .dayTooYoung:
                Text("insights.sameTimeBaseline.gate.dayTooYoung")
            case .unsupportedType:
                Text("insights.sameTimeBaseline.gate.unsupportedType")
            case .notImplemented, .unknown:
                // A reason this build does not model reads as the same calm
                // "not yet", never as an error.
                Text("insights.sameTimeBaseline.gate.notYet")
            }
        }
        .font(.hlCaption)
        .foregroundStyle(HLText.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("insights.sameTimeBaseline.gate")
    }

    // MARK: - Formatting

    private static let chartHeight: CGFloat = 160

    /// Locale-aware rendering of a server figure. The server does NOT round
    /// `todayValue` / `typicalValue` (a median of integers can be `x.5`), so a
    /// half step is shown as a half step rather than being quietly re-rounded.
    private func number(_ value: Double) -> String {
        let isWhole = value == value.rounded()
        return HLNumberFormat.decimal(value, fractionDigits: isWhole ? 0 : 1)
    }
}
