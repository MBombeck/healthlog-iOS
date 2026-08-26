import Accessibility
import Charts
import SwiftUI

/// Per-night sleep-stage composition over 7 / 14 / 30 nights, plus the stage
/// percentages for the active window (parity Build 4 · item 4.7).
///
/// Mirrors the web `sleep-stage-stacked-bar.tsx`: one stacked column per night,
/// Apple Health's sleep tab as the visual reference, a 7 / 14 / 30-day toggle
/// defaulting to 7. The audit recorded BOTH the chart (`09-…md:121`) and the
/// stage percentages (`:122`) as missing on iOS — the hypnogram legend showed
/// per-stage MINUTES for one night and nothing across nights.
///
/// The toggle is a pure client-side tail slice of the one trailing-30-night
/// array the server already sent, so switching windows costs no round-trip.
/// The percentage rows are computed from the SLICED nights, so they always
/// describe the columns actually on screen rather than a fixed 30-day average.
struct SleepStageCompositionCard: View {
    let breakdown: SleepStageBreakdownDTO

    @State private var window: SleepStageWindow = .week

    /// The nights the chart paints — the trailing slice for the active window.
    private var nights: [SleepStageNight] {
        SleepStageComposition.trailing(breakdown.perNight, days: window.days)
    }

    /// Per-stage shares of the SLICED window (not the server's 30-day totals).
    private var shares: [SleepStageComposition.Share] {
        SleepStageComposition.shares(of: SleepStageComposition.totals(of: nights))
    }

    var body: some View {
        if !breakdown.perNight.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("sleep.composition.section")
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        HLRangePicker(selection: $window, style: .inline)
                        if nights.isEmpty || shares.isEmpty {
                            // Stage-less nights in the window (a source that
                            // reports only a total). Say so; do not draw an
                            // empty axis that looks like zero sleep.
                            Text("sleep.composition.noStages")
                                .font(.hlFootnote)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            chart
                                .frame(height: 180)
                                .accessibilityLabel(Text("sleep.composition.a11y"))
                                .accessibilityValue(Text(accessibilitySummary))
                            Text("sleep.composition.caption \(nights.count)")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                            percentageRows
                        }
                    }
                }
            }
        }
    }

    // MARK: - Chart

    /// One stacked column per night. `IN_BED` is NOT a stack member — it is the
    /// container total (≈ the other stages summed), so stacking it would double
    /// every column, the exact defect the web component documents.
    private var chart: some View {
        Chart {
            ForEach(nights) { night in
                ForEach(SleepStageComposition.stackOrder, id: \.self) { stage in
                    if let minutes = night.stages[stage], minutes > 0 {
                        BarMark(
                            x: .value("Night", night.dayKey),
                            y: .value("Minutes", minutes)
                        )
                        .foregroundStyle(color(for: stage))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        // Hours read better than a 480-minute tick.
                        Text(verbatim: "\(Int(minutes / 60))")
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            // Only the window edges are labelled: at 30 columns on a 393 pt
            // screen every per-night tick collides, and a rotated forest of
            // dates is less legible than none.
            AxisMarks(values: edgeDayKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(SleepNightDay.label(forDayKey: key) ?? key)
                            .font(.hlCaption2)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
        }
        // A stacked column chart without a descriptor is a wall of silence to
        // VoiceOver: the label alone says "sleep composition" and nothing about
        // any individual night. The descriptor exposes ONE point per night —
        // total time asleep — so the audio-graph rotor can walk the window the
        // way a sighted user scans the columns. The per-stage split is already
        // spoken by the share rows below the chart, so it is not duplicated here.
        .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))
    }

    /// `AXChartDescriptor` for VoiceOver: x = the night, y = total asleep
    /// minutes (the stacked stages summed — `IN_BED` stays excluded, exactly as
    /// in the drawn stack).
    private var chartDescriptor: AXChartDescriptor {
        let points: [(x: Double, y: Double, xLabel: String)] = nights.enumerated().map { index, night in
            // `stages` is [SleepStage: Int] — widen per term, not at the end.
            let total = SleepStageComposition.stackOrder.reduce(0.0) { sum, stage in
                sum + Double(night.stages[stage] ?? 0)
            }
            return (
                x: Double(index),
                y: total,
                xLabel: SleepNightDay.label(forDayKey: night.dayKey) ?? night.dayKey
            )
        }
        return HLChartAX.singleSeries(
            title: String(localized: "sleep.composition.a11y"),
            summary: accessibilitySummary,
            xAxisTitle: String(localized: "sleep.composition.a11y.xAxis"),
            yAxisTitle: String(localized: "sleep.composition.a11y.yAxis"),
            seriesName: String(localized: "sleep.composition.a11y.series"),
            points: points,
            yValueLabel: { minutes in
                String(format: String(localized: "sleep.composition.a11y.minutes"), Int(minutes))
            }
        )
    }

    /// First + last night of the window — the only two x labels that fit.
    private var edgeDayKeys: [String] {
        guard let first = nights.first?.dayKey, let last = nights.last?.dayKey else { return [] }
        return first == last ? [first] : [first, last]
    }

    // MARK: - Stage percentages

    /// The per-stage share rows the audit flagged as missing (`09-…md:122`).
    /// Minutes AND percent, because a percentage without its absolute is a
    /// figure the reader cannot sanity-check.
    private var percentageRows: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            ForEach(shares) { share in
                HStack(spacing: HLSpace.sm) {
                    RoundedRectangle(cornerRadius: HLRadius.xs)
                        .fill(color(for: share.stage))
                        .frame(width: 12, height: 12)
                    Text(share.stage.displayKey)
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Text(SleepDurationFormat.hoursMinutes(share.minutes))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .monospacedDigit()
                    Text("sleep.composition.percent \(share.percent)")
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Spoken summary for the chart — the same shares the rows print, so
    /// VoiceOver hears the composition rather than "chart".
    private var accessibilitySummary: String {
        shares
            .map { "\(String(localized: $0.stage.displayKey)) \(HLNumberFormat.percent($0.percent))" }
            .joined(separator: ", ")
    }

    /// The sanctioned per-phase category colors, shared verbatim with the
    /// hypnogram (`SleepHypnogramScreen.color(for:)`) so one stage is one
    /// colour across the whole sleep page.
    private func color(for stage: SleepStage) -> Color {
        switch stage {
        case .awake: HLColor.sleepStageAwake
        case .inBed: HLColor.sleepStageInBed
        case .asleep: HLColor.sleepStageAsleep
        case .rem: HLColor.sleepStageREM
        case .core: HLColor.sleepStageCore
        case .deep: HLColor.sleepStageDeep
        }
    }
}

/// 7 / 14 / 30-night window for the composition chart, on the canonical
/// ``HLRangePicker`` so it looks and speaks like every other range control in
/// the app rather than a fourth bespoke toggle.
enum SleepStageWindow: CaseIterable, Hashable, HLRangeOption {
    case week
    case fortnight
    case month

    var id: Self {
        self
    }

    /// Nights in the window — the tail slice length.
    var days: Int {
        switch self {
        case .week: 7
        case .fortnight: 14
        case .month: 30
        }
    }

    var label: String {
        switch self {
        case .week: String(localized: "sleep.composition.window.7")
        case .fortnight: String(localized: "sleep.composition.window.14")
        case .month: String(localized: "sleep.composition.window.30")
        }
    }

    var rangeAccessibilityLabel: String {
        String(localized: "sleep.composition.window.a11y \(days)")
    }
}
