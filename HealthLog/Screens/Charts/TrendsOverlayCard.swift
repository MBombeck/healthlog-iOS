import Charts
import SwiftUI

/// Apple-Health-style multi-metric overlay chart, anchored at the top of
/// the `ChartsScreen` ("Trends") tab.
///
/// **Why this exists (v0.4.0 charts marathon, Stream Charlie, Phase 7):**
/// The previous Trends entry-point was a flat list of per-metric mini-cards
/// — useful for drilling in but no way to spot *correlations*. Apple Health
/// surfaces an overlay at the very top so the user can see "weight + resting
/// pulse trending up together" or "BP stabilising as sleep improves" at a
/// glance. This card brings the same affordance.
///
/// **What you see:**
/// 1. Per-series chip row (user-selectable: BP, Weight, Pulse, Glucose, Sleep,
///    Steps, SpO2, Body Fat, Body Water, Bone Mass) — chips tint to their
///    metric color when active, dim when inactive. Toggling re-fetches.
/// 2. Segmented period picker (W / M / 6M / J).
/// 3. Multi-series overlay: each selected metric plotted as a LineMark in
///    its own tint, on a shared unit-less z-score y-axis (Apple's pattern —
///    raw values would have weight crushed against the bottom).
/// 4. AXChartDescriptor (multi-series) so VoiceOver can rotor between metrics.
struct TrendsOverlayCard: View {
    @Bindable var store: TrendsOverlayStore
    /// v0.11 — canonical scrub-to-read on the single-metric raw chart
    /// (AUDIT-FINAL §H1). The multi-metric z-score overlay stays static (a
    /// single cursor can't read N independent z-series at once).
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            header
            chipRow
            picker
            // Averaging picker is single-metric-only; in multi-metric mode the
            // z-score chart smooths via mean-centring already, so a second
            // aggregation knob would be redundant.
            if case .raw = store.mode {
                averagingPicker
            }
            chartCard
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HLSectionLabel("Trend overview")
            Text(insightText)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
        }
    }

    /// Compact insight line. Branches on overlay mode:
    /// - 0 metrics → "Waehle eine Metrik".
    /// - 1 metric → "<Metrik> — Werte in <Einheit>" (raw mode is plotted in
    ///   native units, so the unit must be announced).
    /// - n metrics → "n Metriken im Vergleich — z-Werte" (unit-less axis).
    private var insightText: String {
        let count = store.selectedMetrics.count
        if count == 0 {
            return String(localized: "Pick a metric below to compare trends.")
        }
        if count == 1, let only = store.selectedMetrics.first {
            let unit = only.unit
            if unit.isEmpty {
                return String(localized: "\(only.displayName) — values over time.")
            }
            return String(localized: "\(only.displayName) — values in \(unit).")
        }
        return String(localized: "\(count) metrics compared — z-scores against each metric's mean.")
    }

    // MARK: - Chip row

    /// Horizontal scrolling chip row — each chip toggles a metric on/off in
    /// the overlay. Inactive chips render dimmed; active chips tint to their
    /// metric color. Mirrors Apple Health's "Datenquellen" chip strip.
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(TrendsOverlayStore.availableMetrics) { kind in
                    MetricToggleChip(
                        kind: kind,
                        isActive: store.selectedMetrics.contains(kind)
                    ) {
                        store.toggle(kind)
                    }
                }
            }
            .padding(.horizontal, HLSpace.hair) // hairline so chip-borders aren't clipped
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Select metrics"))
    }

    // MARK: - Period picker

    private var picker: some View {
        // v0.11 — canonical `HLRangePicker` (.inline). Same segmented control,
        // same monochrome key, same a11y as every other chart's range picker.
        HLRangePicker(selection: $store.range, style: .inline)
    }

    // MARK: - Averaging picker (single-metric raw mode)

    /// Apple-Health-style aggregation control. "Roh" = no aggregation,
    /// "Tag"/"Woche"/"Monat" = per-bucket mean. Wired through
    /// `TrendsOverlayStore.averaging`. Re-render only — no re-fetch.
    private var averagingPicker: some View {
        // v0.6.1.6 — Y6 — AP-005: same monochrome lock as `picker` above.
        Picker(String(localized: "chart.aggregation.label"), selection: $store.averaging) {
            ForEach(TrendsOverlayStore.Averaging.allCases) { mode in
                Text(mode.label)
                    .accessibilityLabel(Text(mode.accessibilityLabel))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .tint(HLText.primary)
        .accessibilityLabel(Text("Select aggregation"))
    }

    // MARK: - Chart card

    private var chartCard: some View {
        HLCard {
            if store.normalisedSeries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: HLChartStyle.heightDetail)
            } else if case let .raw(kind) = store.mode, let raw = store.rawSeries {
                rawChart(for: kind, series: raw)
                    .frame(height: HLChartStyle.heightDetail)
                    .accessibilityChartDescriptor(HLChartDescriptor(makeRawAXDescriptor(kind: kind)))
            } else {
                chart
                    .frame(height: HLChartStyle.heightDetail)
                    .accessibilityChartDescriptor(HLChartDescriptor(makeAXDescriptor()))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.hlIcon(HLIconSize.hero, weight: .regular))
                .foregroundStyle(HLText.tertiary)
            Text(store.isLoading
                ? String(localized: "Loading history …")
                : (store.selectedMetrics.isEmpty
                    ? String(localized: "No metrics selected")
                    : String(localized: "No data in this period")))
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
        }
        .padding(.vertical, HLSpace.lg)
    }

    /// Raw-value chart for single-metric mode. Plots `aggregatedRawPoints`
    /// (which respects the user's averaging picker) on a y-axis labelled with
    /// the metric's native unit. Matches Apple Health's single-metric pattern.
    private func rawChart(for kind: MetricKind, series _: TrendsOverlayStore.NormalisedSeries) -> some View {
        let points = store.aggregatedRawPoints
        let tint = Self.tint(for: kind)
        return Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value(String(localized: "Time"), p.at),
                    y: .value(kind.unit, p.value)
                )
                .foregroundStyle(tint)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                // BP carries a secondary (diastolic) value — draw it as a
                // second mark in the mid-emphasis Theme-2.0 tint
                // (`HLChartTints.seriesMid` = Dracula-Purple at ~70%). This
                // routes the diastolic line through the semantic chart-series
                // ramp instead of the raw `HLColor.cyan` drift that T2-3 left
                // behind (PB-T2-5 backlog HIGH:190 — Theme-2.1 candidate
                // promoted into Visual-Polish-1 since we were already in this
                // file). Primary systolic stays at full opacity, diastolic
                // sits visually behind it via the opacity ramp.
                if let secondary = p.secondary {
                    LineMark(
                        x: .value(String(localized: "Time"), p.at),
                        y: .value(kind.unit, secondary),
                        series: .value(String(localized: "Diastolic"), "diastolic")
                    )
                    .foregroundStyle(HLChartTints.seriesMid)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                }
            }
            // Canonical scrub overlay — reuses `SelectedPointCallout` since the
            // raw points are `SeriesPoint` (BP-secondary aware), identical to
            // the ChartDetail scrubber.
            HLChartScrubber.marks(
                selectedDate: selectedDate,
                in: points,
                date: \.at,
                value: \.value
            ) { point in
                SelectedPointCallout(point: point, kind: kind, isPersonalRecord: false)
            }
        }
        .hlChartScrub($selectedDate) { date in
            guard let nearest = HLChartScrubber.nearest(to: date, in: points, date: \.at) else { return nil }
            return String(
                localized: "\(nearest.at.formatted(.dateTime.day().month())): \(nearest.value.formatted(.number.precision(.fractionLength(0 ... 1)))) \(kind.unit)"
            )
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v.formatted(.number.precision(.fractionLength(0 ... 1))))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
            }
        }
        // SwiftUI Charts auto-formats the y-tick numbers; the unit label is
        // hoisted to a single rotated axis title so narrow widths don't have
        // "kg" repeated on every tick.
        .chartYAxisLabel(position: .leading, alignment: .center) {
            Text(kind.unit)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.day().month(.abbreviated))
                    }
                    AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                }
            }
        }
        .hlAnimation(.snappy(duration: 0.35), value: store.queryKey)
    }

    /// AX descriptor for the single-metric raw chart. Reuses Echo's
    /// `HLChartAX.singleSeries` so VoiceOver speaks the same shape as the
    /// dashboard mini-sparklines / mood chart.
    private func makeRawAXDescriptor(kind: MetricKind) -> AXChartDescriptor {
        let points = store.aggregatedRawPoints
        let payload: [(x: Double, y: Double, xLabel: String)] = points.enumerated().map { idx, p in
            let xLabel = Self.axDateFormatter.string(from: p.at)
            return (x: Double(idx), y: p.value, xLabel: xLabel)
        }
        let summary = if payload.isEmpty {
            String(localized: "No data")
        } else {
            String(localized: "\(kind.displayName), \(payload.count) values in \(kind.unit)")
        }
        return HLChartAX.singleSeries(
            title: String(localized: "Trend overview"),
            summary: summary,
            xAxisTitle: String(localized: "Time"),
            yAxisTitle: kind.unit.isEmpty ? kind.displayName : kind.unit,
            seriesName: kind.displayName,
            points: payload,
            yValueLabel: { v in
                "\(v.formatted(.number.precision(.fractionLength(0 ... 1)))) \(kind.unit)"
            }
        )
    }

    private var chart: some View {
        Chart {
            ForEach(store.normalisedSeries) { series in
                ForEach(series.normalisedPoints, id: \.at) { point in
                    LineMark(
                        x: .value(String(localized: "Time"), point.at),
                        y: .value(String(localized: "chart.axis.zscore"), point.z),
                        series: .value("metric", series.kind.rawValue)
                    )
                    .foregroundStyle(by: .value(String(localized: "Metric"), series.kind.displayName))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round))
                }
            }
        }
        // Tint legend: drive series colors from the metric palette so they
        // match the per-metric mini-cards + dashboard tiles.
        .chartForegroundStyleScale(
            domain: store.normalisedSeries.map(\.kind.displayName),
            range: store.normalisedSeries.map { Self.tint(for: $0.kind) }
        )
        // Y-axis is unit-less (z-scores) — show ±2 reference lines as gridlines
        // but no numeric labels (Apple's pattern: reader interprets slopes).
        .chartYAxis {
            AxisMarks(values: [-2, 0, 2]) { value in
                AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                if let v = value.as(Double.self), v == 0 {
                    AxisValueLabel {
                        Text("ø")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
            }
        }
        // Announce the unit-less axis explicitly so the multi-metric mode
        // doesn't read as "broken kg". The label sits rotated at the y-axis
        // root and never crowds the per-tick legend.
        .chartYAxisLabel(position: .leading, alignment: .center) {
            Text("Deviation from average")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.day().month(.abbreviated))
                    }
                    AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .hlAnimation(.snappy(duration: 0.35), value: store.queryKey)
    }

    // MARK: - Per-metric tint (v0.5.2-R1 reconcile: tint-aware ramp)

    /// Resolves a per-metric tint for the multi-series overlay.
    ///
    /// **History:** T2-3 collapsed this routing onto `HLChartTints.series`
    /// (single Dracula-Purple) so single-metric charts render in one calm
    /// tone. Operator real-device walkthrough on `v0.5.3.5-rc-theme-2.0`
    /// flagged that when the overlay plots 2+ metrics, the lines become
    /// indistinguishable. Visual-Polish-1 (2026-05-16) restored per-metric
    /// differentiation through a fixed 4-tint Dracula ramp.
    ///
    /// **v0.5.2-R1 reconcile (2026-05-17):** the fixed Dracula ramp
    /// collided with the user-picked accent — operator picks `.cyan` →
    /// weight series cyan AND BP series cyan, identical lines. The ramp
    /// now leads with the user accent (`HLChartTints.series`) and
    /// companions paint in a monochrome graphite step so the accent line
    /// is always the "headline" regardless of the user's pick. Information
    /// lives in the colour-bright line; companions differentiate by
    /// lightness only. Theme-2.0 single-accent contract holds.
    ///
    /// The mapping is **deterministic + stable** — anchored to
    /// `MetricKind.allCases` index so the same metric always renders in
    /// the same lightness step across sessions, app launches, and
    /// chip-toggle order. Past position 4 the ramp cycles via modulo;
    /// typical operator usage shows 2-4 metrics overlaid, not 5+, so the
    /// cycle is rarely visible.
    ///
    /// Raw-mode (single-metric) callers receive the primary accent
    /// (`HLChartTints.series`) — they have only one line to draw, so the
    /// ramp doesn't apply. The function is shared because the chip-row
    /// swatch needs the same metric→tint mapping as the chart series.
    static func tint(for kind: MetricKind) -> Color {
        let index = MetricKind.allCases.firstIndex(of: kind) ?? 0
        let ramp = HLChartTints.multiSeriesRamp
        return ramp[index % ramp.count]
    }

    // MARK: - AX descriptor

    private static let axDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private func makeAXDescriptor() -> AXChartDescriptor {
        let allDates = store.normalisedSeries.flatMap(\.normalisedPoints).map(\.at)
        let xLower = allDates.min()?.timeIntervalSince1970 ?? 0
        let xUpper = (allDates.max()?.timeIntervalSince1970 ?? 1).advanced(by: 1)

        let series: [(name: String, points: [(x: Double, y: Double)], continuous: Bool)] =
            store.normalisedSeries.map { ns in
                let mapped = ns.normalisedPoints.map { p in
                    (x: p.at.timeIntervalSince1970, y: p.z)
                }
                return (name: ns.kind.displayName, points: mapped, continuous: true)
            }

        let summary = if store.normalisedSeries.isEmpty {
            String(localized: "No data")
        } else {
            String(localized: "\(store.normalisedSeries.count) metrics compared, z-scores against the mean")
        }

        return HLChartAX.multiSeries(
            title: String(localized: "Trend overview"),
            summary: summary,
            xAxisTitle: String(localized: "Time"),
            yAxisTitle: String(localized: "chart.axis.zscore"),
            xRange: xLower ... xUpper,
            yRange: -3.0 ... 3.0,
            series: series,
            xValueLabel: { v in
                let date = Date(timeIntervalSince1970: v)
                return Self.axDateFormatter.string(from: date)
            },
            yValueLabel: { v in
                "\(HLNumberFormat.decimal(v, fractionDigits: 1)) σ"
            }
        )
    }
}

// MARK: - Per-metric toggle chip

private struct MetricToggleChip: View {
    let kind: MetricKind
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HLSpace.xs) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(kind.displayName)
                    .font(.hlCaption.weight(.semibold))
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(
                Capsule().fill(isActive ? tint.opacity(HLOpacity.surfaceTintStrong) : HLColor.surface)
            )
            .foregroundStyle(isActive ? tint : HLText.secondary)
            .overlay(
                Capsule().stroke(isActive ? tint.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.displayName))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(Text(isActive
                ? String(localized: "Double-tap to deselect")
                : String(localized: "Double-tap to select")))
    }

    // Visual-Polish-1: chip swatch routes through the same per-metric ramp
    // as the chart line so the dot you tap matches the colour you read on
    // the chart. Active/inactive contrast still comes from the surrounding
    // capsule opacity, not the swatch hue (capsule fades to surface when
    // inactive — see `background` modifier above).
    private var tint: Color {
        TrendsOverlayCard.tint(for: kind)
    }
}
