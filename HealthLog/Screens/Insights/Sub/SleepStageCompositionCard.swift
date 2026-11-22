import Accessibility
import Charts
import SwiftUI

/// Per-night sleep-stage composition over the page's time range, plus the
/// stage percentages for those nights (parity Build 4 · item 4.7).
///
/// Mirrors the web `sleep-stage-stacked-bar.tsx`: one stacked column per night,
/// Apple Health's sleep tab as the visual reference.
///
/// The card has no time range of its own: it follows the page's one period
/// control. The server sends the trailing 30 nights, so a longer range shows
/// all of them; the slice is client-side and costs no round-trip. The
/// percentage rows are computed from the SLICED nights, so they always
/// describe the columns actually on screen.
struct SleepStageCompositionCard: View {
    let breakdown: SleepStageBreakdownDTO
    /// The days of the page's selected range (`HLTimeRange.days`).
    var rangeDays: Int = SleepStageCompositionCard.maxNights

    /// The server's trailing window; no range shows more nights than this.
    nonisolated static let maxNights = 30

    /// How many nights a page range shows: at least one, at most the 30 the
    /// server sends.
    nonisolated static func nightCount(forRangeDays days: Int) -> Int {
        min(max(days, 1), maxNights)
    }

    /// The nights the chart paints — the trailing slice for the page's range.
    private var nights: [SleepStageNight] {
        SleepStageComposition.trailing(breakdown.perNight, days: Self.nightCount(forRangeDays: rangeDays))
    }

    /// Per-stage shares of the SLICED window (not the server's 30-day totals).
    private var shares: [SleepStageComposition.Share] {
        SleepStageComposition.shares(of: SleepStageComposition.totals(of: nights))
    }

    /// A source that reports only a total has no stages in any
    /// night: then the card is not there at all instead of saying so.
    private var hasAnyStages: Bool {
        !SleepStageComposition.shares(of: SleepStageComposition.totals(of: breakdown.perNight)).isEmpty
    }

    var body: some View {
        if hasAnyStages {
            Group {
                HLSectionHeader("sleep.composition.section", rank: .area)
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        if nights.isEmpty || shares.isEmpty {
                            // Stage-less nights in this range only (other
                            // ranges have stages). Say so; do not draw an
                            // empty axis that looks like zero sleep.
                            HLEmptyNote("sleep.composition.noStages")
                        } else {
                            // The page's period control names the range.
                            chart
                                .frame(height: HLChartStyle.heightRegular)
                                .accessibilityLabel(Text("sleep.composition.a11y"))
                                .accessibilityValue(Text(accessibilitySummary))
                            percentageRows
                        }
                        // 1.0.3 (App Review 1.4.1, audit row 17) — the stage
                        // shares are read against what a night is expected to
                        // look like, a claim with a literature behind it (AASM
                        // 2015 and the rhythm set). At the card's foot,
                        // where every other card carries its citation.
                        HLSourcesLink(topic: .sleepRhythm)
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
        // Hours on the leading edge: they read better than a 480-minute tick.
        .hlChartValueAxis(label: Self.hoursLabel)
        .hlChartUnit(String(localized: "unit.hours.short"))
        .chartXAxis {
            // Only the window edges are labelled: at 30 columns on a 393 pt
            // screen every per-night tick collides, and a rotated forest of
            // dates is less legible than none.
            AxisMarks(values: edgeDayKeys) { value in
                // The edge labels start and end at their columns, so
                // neither is cut (the app's one date-axis rule).
                AxisValueLabel(anchor: ChartDateAxis.labelAnchor(index: value.index, count: value.count)) {
                    if let key = value.as(String.self) {
                        Text(SleepNightDay.label(forDayKey: key) ?? key)
                            .hlText(.rowSubtitle)
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

    /// A minutes tick as whole hours.
    nonisolated static func hoursLabel(_ minutes: Double) -> String {
        "\(Int(minutes / 60))"
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
                        .hlText(.footnote)
                        .monospacedDigit()
                    Text("sleep.composition.percent \(share.percent)")
                        .hlText(.note)
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
