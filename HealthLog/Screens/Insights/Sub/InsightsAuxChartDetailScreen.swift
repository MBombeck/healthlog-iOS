import Accessibility
import Charts
import SwiftUI

// v0.6.2.9 Y10.8-C — auxiliary chart-detail destinations for Insights
// tiles that don't map onto a `MetricKind`. The Ziele-Metric tile grid
// (`InsightsTargetTileGrid`) already pushes `ChartDetailScreen` for
// metric-shaped tiles (Gewicht, Ruhepuls, Schritte …); this file
// supplies the parallel push-destination for the three tiles that
// route through their own data path:
//
// - `InsightsAuxMoodDetailScreen` — Stimmung tile → mood-score history
// - `InsightsAuxMoodStabilityDetailScreen` — Stabilität tile → mood
//   spread/variance over time
// - `InsightsAuxComplianceDetailScreen` — Compliance tile →
//   medication-adherence heatmap + headline stats
//
// Each destination mirrors the `ChartDetailScreen` anatomy at a
// stripped-down level: hero strip with the headline number + range,
// chart card (re-using existing components like `MoodTrendChart` or
// `ComplianceHeatmapSection`), then any auxiliary cards (mood summary,
// per-medication compliance list). The screens are pushed onto the
// Insights `NavigationStack`, so they pick up the standard nav-bar
// back chevron for free — no inner stack, no toolbar overrides.

// MARK: - Stimmung (MOOD_SCORE)

/// Detail screen for the Stimmung tile. Pulls from `MoodStore` to plot a
/// trend of the operator's mood entries and surfaces the Insights
/// digest's `moodSummary` (Ø 7T / Ø 30T / Anzahl) when present.
struct InsightsAuxMoodDetailScreen: View {
    @Environment(MoodStore.self) private var moodStore
    @Environment(InsightsStore.self) private var insightsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                heroStrip
                chartCard
                if let summary = insightsStore.digest?.moodSummary {
                    MoodSummaryCard(summary: summary)
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxxl)
        }
        .background(HLColor.background.ignoresSafeArea())
        .hlScrollEdgeSoft()
        .navigationTitle(String(localized: "Mood"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if moodStore.entries.isEmpty { await moodStore.load() } }
    }

    private var heroStrip: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let latest = moodStore.entries.max(by: { $0.recordedAt < $1.recordedAt }) {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                        Text("\(latest.score)")
                            .font(.hlMetric(.largeTitle))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                        Text(String(localized: "of 5"))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Spacer()
                    }
                    Text(latest.recordedAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                } else {
                    Text(String(localized: "No mood entries yet"))
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        let entries = chartEntries
        if entries.count >= 2 {
            HLCard {
                MoodTrendChart(entries: entries)
                    .frame(height: HLChartStyle.heightDetail + 80)
            }
        } else {
            HLCard {
                HLEmptyState(
                    icon: "chart.line.flattrend.xyaxis",
                    title: "Not enough data yet",
                    message: "Log more mood entries to see the history."
                )
            }
        }
    }

    private var chartEntries: [MoodTrendChart.Entry] {
        moodStore.entries
            .sorted(by: { $0.recordedAt < $1.recordedAt })
            .map { MoodTrendChart.Entry(date: $0.recordedAt, score: $0.score) }
    }
}

// MARK: - Stabilität (MOOD_STABILITY)

/// Detail screen for the Stabilität tile. Plots an on-device rolling
/// 7-day spread of mood scores — wider spread = lower stability. The
/// chart uses the same `MoodTrendChart` y-domain so operators see a
/// consistent visual baseline, but the y-axis here represents
/// "consecutive-day score variance" (max − min in a 7-day window).
struct InsightsAuxMoodStabilityDetailScreen: View {
    @Environment(MoodStore.self) private var moodStore
    /// v0.11 — canonical scrub-to-read (AUDIT-FINAL §H1).
    @State private var selectedDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                heroStrip
                chartCard
                explainerCard
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxxl)
        }
        .background(HLColor.background.ignoresSafeArea())
        .hlScrollEdgeSoft()
        .navigationTitle(String(localized: "Stability"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if moodStore.entries.isEmpty { await moodStore.load() } }
    }

    private var heroStrip: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let latestSpread = rollingSpread.last {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                        Text(latestSpread.value.formatted(.number.precision(.fractionLength(0 ... 1))))
                            .font(.hlMetric(.largeTitle))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                        Text(String(localized: "Points range"))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Spacer()
                    }
                    Text(latestSpread.date, format: .dateTime.weekday(.wide).day().month())
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                } else {
                    Text(String(localized: "No stability data yet"))
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        let spread = rollingSpread
        if spread.count >= 2 {
            HLCard {
                Chart {
                    ForEach(spread) { bucket in
                        LineMark(
                            x: .value(String(localized: "chart.axis.date"), bucket.date),
                            y: .value(String(localized: "chart.axis.span"), bucket.value)
                        )
                        .foregroundStyle(HLChartTints.series)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        PointMark(
                            x: .value(String(localized: "chart.axis.date"), bucket.date),
                            y: .value(String(localized: "chart.axis.span"), bucket.value)
                        )
                        .symbolSize(36)
                        .foregroundStyle(HLChartTints.series)
                    }
                    // Canonical scrub overlay.
                    HLChartScrubber.marks(
                        selectedDate: selectedDate,
                        in: spread,
                        date: \.date,
                        value: \.value
                    ) { bucket in
                        HLScrubCallout(
                            title: bucket.date.formatted(.dateTime.weekday(.abbreviated).day().month()),
                            value: bucket.value.formatted(.number.precision(.fractionLength(1))),
                            unit: String(localized: "Points range")
                        )
                    }
                }
                .chartYScale(domain: 0 ... 4)
                .hlChartScrub($selectedDate) { date in
                    guard let nearest = HLChartScrubber.nearest(to: date, in: spread, date: \.date) else { return nil }
                    return String(
                        localized: "\(nearest.date.formatted(.dateTime.day().month())): \(nearest.value.formatted(.number.precision(.fractionLength(1)))) points range"
                    )
                }
                .frame(height: HLChartStyle.heightDetail + 80)
                .accessibilityChartDescriptor(HLChartDescriptor(spreadChartDescriptor(spread)))
            }
        } else {
            HLCard {
                HLEmptyState(
                    icon: "waveform.path.ecg",
                    title: "Not enough data yet",
                    message: "Stabilität misst die Schwankung deiner Stimmung über sieben Tage. Logge mindestens zwei Wochen, um den Trend zu sehen."
                )
            }
        }
    }

    private var explainerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("What does this mean?")
                Text(
                    String(
                        localized: "Die Spanne zeigt, wie weit deine Stimmung in den letzten sieben Tagen geschwankt hat — von 0 (stabil) bis 4 (volle Bandbreite)."
                    )
                )
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Rolling 7-day mood-score spread (max − min) computed on-device
    /// from `MoodStore.entries`. Buckets per calendar day; days without
    /// at least two entries in the window collapse out of the chart so
    /// we don't draw a line through "no signal" stretches.
    struct SpreadBucket: Identifiable, Equatable {
        let id: Date
        var date: Date {
            id
        }

        let value: Double
    }

    private var rollingSpread: [SpreadBucket] {
        Self.computeRollingSpread(entries: moodStore.entries)
    }

    /// AX descriptor for the 7-day mood-spread chart so VoiceOver can rotor
    /// through the daily values (ChartAXCoverage exhaustiveness guard). X is
    /// keyed by bucket index with a date label; Y is the 0…4 point-spread.
    private func spreadChartDescriptor(_ spread: [SpreadBucket]) -> AXChartDescriptor {
        let points = spread.enumerated().map { index, bucket -> (x: Double, y: Double, xLabel: String) in
            (Double(index), bucket.value, bucket.date.formatted(.dateTime.weekday(.abbreviated).day().month()))
        }
        return HLChartAX.singleSeries(
            title: String(localized: "Mood stability"),
            summary: String(localized: "7-day spread of your mood, from 0 (stable) to 4 (full range)."),
            xAxisTitle: String(localized: "chart.axis.date"),
            yAxisTitle: String(localized: "chart.axis.span"),
            seriesName: String(localized: "chart.axis.span"),
            points: points,
            yValueLabel: { value in
                String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) points range")
            }
        )
    }

    /// Pure, testable spread computation. The window for a given `cursor`
    /// covers `[cursor − 6 days, cursor + 1 day)` — inclusive of the day
    /// itself, exclusive of the next day's `startOfDay`. The earlier
    /// implementation used `recordedAt <= cursor` where `cursor` is
    /// `startOfDay(...)`, which silently dropped every mood entry logged
    /// after midnight (i.e. effectively all of "today"). The hero strip
    /// labels the latest spread with today's date, so the data has to
    /// include today's entries — otherwise the headline number lags the
    /// label by 24h.
    nonisolated static func computeRollingSpread(
        entries: [MoodEntry],
        calendar: Calendar = .current
    ) -> [SpreadBucket] {
        let sorted = entries.sorted(by: { $0.recordedAt < $1.recordedAt })
        guard let firstDate = sorted.first?.recordedAt,
              let lastDate = sorted.last?.recordedAt else { return [] }
        // Walk day-by-day from the first logged day so the first bucket
        // has access to a full 7-day backward window.
        let startDay = calendar.startOfDay(for: firstDate)
        let endDay = calendar.startOfDay(for: lastDate)
        var buckets: [SpreadBucket] = []
        var cursor = startDay
        while cursor <= endDay {
            guard let windowStart = calendar.date(byAdding: .day, value: -6, to: cursor),
                  let windowEnd = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let inWindow = sorted.filter { $0.recordedAt >= windowStart && $0.recordedAt < windowEnd }
            if inWindow.count >= 2 {
                let scores = inWindow.map { Double($0.score) }
                if let lo = scores.min(), let hi = scores.max() {
                    buckets.append(SpreadBucket(id: cursor, value: hi - lo))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return buckets
    }
}

// MARK: - Compliance (MEDICATION_COMPLIANCE)

/// Detail screen for the Compliance tile. Surfaces the operator's
/// medication-adherence heatmap (re-uses `ComplianceHeatmapSection`)
/// plus the headline 7 / 30 day numbers from the comprehensive digest.
struct InsightsAuxComplianceDetailScreen: View {
    @Environment(MedicationsStore.self) private var medicationsStore
    @Environment(InsightsStore.self) private var insightsStore
    /// v0.11 (AUDIT-FINAL §H4) — tapped compliance day → summary sheet, so the
    /// compliance heatmap's tap affordance matches the mood heatmap's.
    @State private var selectedDay: ComplianceDay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                heroStrip
                heatmapCard
                perMedicationList
                explainerCard
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxxl)
        }
        .background(HLColor.background.ignoresSafeArea())
        .hlScrollEdgeSoft()
        .navigationTitle(String(localized: "Compliance"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if medicationsStore.medications.isEmpty { await medicationsStore.load() } }
        .sheet(item: $selectedDay) { day in
            ComplianceDaySummarySheet(day: day)
                .hlSheetPresentation(.form)
        }
    }

    private var heroStrip: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let rate30 = aggregateRate30 {
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                        Text("\(Int((rate30 * 100).rounded()))")
                            .font(.hlMetric(.largeTitle))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                        Text("%")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Spacer()
                    }
                    Text(String(localized: "30-day avg"))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                } else {
                    Text(String(localized: "No compliance data yet"))
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            InsightsSectionHeader("History")
            ComplianceHeatmapSection(
                days: medicationsStore.compliance,
                onSelectDay: { selectedDay = $0 }
            )
        }
    }

    @ViewBuilder
    private var perMedicationList: some View {
        if let meds = insightsStore.digest?.medications, !meds.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("Per medication")
                HLCard {
                    VStack(spacing: 0) {
                        ForEach(meds) { med in
                            row(for: med)
                            if med.id != meds.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(for med: MedicationComplianceSummary) -> some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(med.name)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                if let dose = med.dose, !dose.isEmpty {
                    Text(dose)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer()
            if let rate = med.compliance30 {
                Text(HLNumberFormat.percent(Int((rate * 100).rounded())))
                    .font(.hlMetric(.headline))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            } else {
                Text("—")
                    .font(.hlBody)
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .padding(.vertical, HLSpace.sm)
    }

    private var explainerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("What does this mean?")
                Text(
                    String(
                        localized: "Compliance misst, wie verlässlich du deine geplanten Einnahmen wirklich loggst — über alle aktiven Medikamente hinweg."
                    )
                )
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Aggregate 30-day rate across every active medication. Mirrors the
    /// dashboard's "Compliance Ø 30 T" reading by averaging the
    /// per-medication `compliance30` values from the comprehensive digest
    /// when available; falls back to the on-device `ComplianceDay` array
    /// from `MedicationsStore` so we always paint a number when there is
    /// any signal at all.
    private var aggregateRate30: Double? {
        if let meds = insightsStore.digest?.medications, !meds.isEmpty {
            let rates = meds.compactMap(\.compliance30)
            if !rates.isEmpty {
                return rates.reduce(0, +) / Double(rates.count)
            }
        }
        let last30 = medicationsStore.compliance
            .sorted(by: { $0.date > $1.date })
            .prefix(30)
        // Mirror the heatmap's rate label (ComplianceHeatmapSection): average
        // over `scheduledRate` so 0/0 no-dose days are excluded from the
        // denominator instead of folded in as 0 — using `\.rate` here dragged
        // the mean toward 0 on every unscheduled day.
        let rates = last30.compactMap(\.scheduledRate)
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }
}

// MARK: - Compliance day summary sheet (v0.11 §H4)

/// Lightweight day summary presented when the operator taps a cell in the
/// compliance heatmap — the iOS twin of the mood heatmap's "open that day"
/// affordance. There's no per-day intake screen in the app today, so this
/// surfaces the same taken/scheduled/status read the cell encodes, plus its
/// percentage, in a compact form sheet.
private struct ComplianceDaySummarySheet: View {
    let day: ComplianceDay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    HLCard(style: .elevated) {
                        VStack(alignment: .leading, spacing: HLSpace.sm) {
                            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                                Text("\(Int((day.rate * 100).rounded()))")
                                    .font(.hlMetric(.largeTitle))
                                    .foregroundStyle(HLText.primary)
                                    .monospacedDigit()
                                Text("%")
                                    .font(.hlSubhead)
                                    .foregroundStyle(HLText.secondary)
                                Spacer()
                                HLBadge(statusWord, tone: statusTone)
                            }
                            Text(day.date, format: .dateTime.weekday(.wide).day().month().year())
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                    HLCard {
                        VStack(spacing: 0) {
                            summaryRow(String(localized: "insights.aux.scheduled"), value: "\(day.scheduled)")
                            Divider()
                            summaryRow(String(localized: "Taken"), value: "\(day.taken)")
                            Divider()
                            summaryRow(String(localized: "insights.aux.missed"), value: "\(Swift.max(day.scheduled - day.taken, 0))")
                        }
                    }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
            }
            .background(HLColor.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Day"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer()
            Text(value)
                .font(.hlMetric(.headline))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
        }
        .padding(.vertical, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }

    private var status: ComplianceStatusPalette.Status {
        ComplianceStatusPalette.status(for: day)
    }

    private var statusWord: String {
        switch status {
        case .none: String(localized: "med.heatmap.status.none")
        case .taken: String(localized: "med.heatmap.status.taken")
        case .partial: String(localized: "med.heatmap.status.partial")
        case .missed: String(localized: "med.heatmap.status.missed")
        }
    }

    private var statusTone: HLBadge.Tone {
        switch status {
        case .none: .neutral
        case .taken: .success
        case .partial: .warning
        case .missed: .critical
        }
    }
}
