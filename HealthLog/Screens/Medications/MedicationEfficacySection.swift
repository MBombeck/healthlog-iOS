import Accessibility
import Charts
import SwiftUI

/// v1.28 (GH iOS #45) — the medication-efficacy ("Wirkung") section on the
/// medication detail screen.
///
/// **Association-only — a safety/trust surface.** This view relates a
/// medication to the outcome metric/lab its class is prescribed to move, around
/// the medication's start. It renders the SERVER-authoritative efficacy DTO
/// verbatim (``MedicationEfficacyDTO``) — it never recomputes a delta, a mean,
/// or an adherence rate on device (PROJECT_GUIDE.md Med-Compliance rule). The copy
/// describes a **temporal association**, nothing causal: NO verdict, NO efficacy
/// score, NO "works / doesn't work" wording, NO dose advice. The banned-word
/// guard `MedicationEfficacyCopyGuardTests` enforces that structurally.
///
/// **Honest insufficient-data states.** A short/empty series renders a plain
/// "no readings yet" line; a missing before/after renders the server's honest
/// reason (need-before / need-after / need-start / need-data); a missing start
/// renders a "set a start date" note. Nothing misleading is drawn.
///
/// The whole section self-suppresses upstream (`store.efficacy == nil` or
/// `!eligible`), so this view always has an eligible DTO to render.
///
/// **Design:** monochrome (graphite series + tokens reused from `BiomarkerChart`
/// / `HLChartTints`); the start marker is the one accent ("signal-colour only
/// for markers"). Chart primitive vocabulary (`Chart` + `LineMark`/`PointMark`/
/// `RuleMark`/`RectangleMark` + `HLChartStyle`/`HLChartGrid`) mirrors the
/// metric/biomarker detail charts.
struct MedicationEfficacySection: View {
    let efficacy: MedicationEfficacyDTO
    /// Pin / clear the tracked target. Sync (fire-and-forget) — the screen
    /// wraps it in a `Task` calling the store, which owns the async PUT +
    /// re-fetch and surfaces any failure via the shared `ErrorBanner`. Same
    /// idiom as `LedgerHistorySection`'s retro-mutate callbacks.
    let onSelectTarget: (EfficacyTargetSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("med.wirkung.title")

            // Wirkung is chart-and-number-forward (web parity, 2026-07-18): the
            // two generic MDR prose blocks (med.wirkung.intro / .disclaimer) were
            // removed — they read as a confusing text wall above the chart. The
            // honest, data-specific captions below (startFallback / noStart /
            // levelShift) stay. Verdict wording remains banned structurally by
            // MedicationEfficacyCopyGuardTests.
            if efficacy.markers.startFromFirstReading {
                Text("med.wirkung.startFallback")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if efficacy.markers.start == nil {
                Text("med.wirkung.noStart")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !efficacy.overrideOptions.isEmpty {
                EfficacyRetargetControl(
                    options: efficacy.overrideOptions,
                    isOverride: efficacy.resolution.isOverride,
                    onSelectTarget: onSelectTarget
                )
            }

            ForEach(efficacy.targets) { target in
                EfficacyTargetCard(
                    target: target,
                    markers: efficacy.markers,
                    adherence: efficacy.adherence,
                    minWeeksPerSide: efficacy.minWeeksPerSide
                )
            }
        }
    }
}

// MARK: - Per-target card

/// One tracked outcome: its label + primary badge, the series chart with
/// markers, the before/after-start comparison, an adherence readout, and the
/// optional conservative level-shift note.
private struct EfficacyTargetCard: View {
    let target: MedicationEfficacyDTO.Target
    let markers: MedicationEfficacyDTO.Markers
    let adherence: [MedicationEfficacyDTO.AdherencePoint]
    let minWeeksPerSide: Int

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                header

                if target.series.count >= 2 {
                    EfficacyTargetChart(target: target, markers: markers)
                } else {
                    Text("med.wirkung.noSeries")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, HLSpace.sm)
                }

                EfficacyBeforeAfterCard(
                    beforeAfter: target.beforeAfter,
                    unit: target.unit,
                    minWeeksPerSide: minWeeksPerSide
                )

                if !adherence.isEmpty {
                    EfficacyAdherenceReadout(points: adherence)
                }

                if let shift = target.levelShift, shift.isNearStart, let at = shift.at {
                    Text(levelShiftText(at))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(verbatim: target.label)
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            if target.primary {
                Text("med.wirkung.primaryBadge")
                    .font(.hlCaption2.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xxs)
                    .background(HLSurface.tertiary, in: Capsule())
            }
        }
    }

    private func levelShiftText(_ at: Date) -> String {
        String(
            format: String(localized: "med.wirkung.levelShift"),
            at.formatted(.dateTime.day().month(.abbreviated).year())
        )
    }
}

// MARK: - Chart

/// The target series over time with the medication's markers overlaid. Reuses
/// the app chart vocabulary (`HLChartStyle` / `HLChartGrid` / `HLChartTints`)
/// like `BiomarkerChart`: a faint "typical range" reference band, shaded pause
/// bands, the monochrome series line + dots, a dashed dose-change rule per
/// change, and a single accent start marker. A legend beneath names each mark.
private struct EfficacyTargetChart: View {
    let target: MedicationEfficacyDTO.Target
    let markers: MedicationEfficacyDTO.Markers

    /// Chronological series (the DTO order is not guaranteed).
    private var points: [MedicationEfficacyDTO.Target.Point] {
        target.series.sorted { $0.t < $1.t }
    }

    /// Where an open pause (`to == nil`) runs to — the latest datum, so the
    /// render stays pure (no `Date.now` in the body).
    private var rightEdge: Date? {
        points.last?.t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            chart
                .frame(height: HLChartStyle.heightDetail)
                .accessibilityLabel(Text("med.wirkung.chart.a11y"))
            legend
        }
    }

    private var chart: some View {
        Chart {
            referenceBandMark
            pauseMarks
            seriesMarks
            doseChangeMarks
            startMark
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisTick().foregroundStyle(HLText.tertiary)
                AxisValueLabel().font(.hlCaption).foregroundStyle(HLText.secondary)
            }
        }
        .chartXAxis {
            // Bounded tick count (was `.automatic`, which emitted a date under
            // nearly every point on a dense 20–30-reading series → the
            // overlapping-dates wall the operator flagged). Label routed through
            // the shared HLDateFormat so it honours the user's date-order pref
            // and matches the rest of the app.
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(HLDateFormat.date(date, style: .abbreviated))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    AxisGridLine().foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                }
            }
        }
        .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))
    }

    /// `AXChartDescriptor` for VoiceOver — x = the reading date (spoken as a
    /// medium date), y = the outcome value (spoken with its unit). Built off the
    /// same chronological `points` series the chart plots so the spoken trend
    /// matches the drawn one. Mirrors `BiomarkerChart.chartDescriptor` /
    /// `HLChartAX.singleSeries`, the path every other line chart uses.
    private var chartDescriptor: AXChartDescriptor {
        let pts = points
        let triples = pts.enumerated().map { idx, point in
            (
                x: Double(idx),
                y: point.value,
                xLabel: point.t.formatted(.dateTime.day().month(.abbreviated).year())
            )
        }
        let unit = target.unit ?? ""
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        return HLChartAX.singleSeries(
            title: String(localized: "med.wirkung.chart.a11y"),
            summary: "",
            xAxisTitle: String(localized: "med.wirkung.axis.date"),
            yAxisTitle: unit.isEmpty ? target.label : unit,
            seriesName: target.label,
            points: triples,
            yValueLabel: { value in
                let formatted = value.formatted(.number.precision(.fractionLength(0 ... 2)))
                return "\(formatted)\(unitSuffix)"
            }
        )
    }

    // MARK: Marks

    /// Population "typical range" — a calm graphite band, context only, NEVER a
    /// goal line (the descriptive-only posture).
    @ChartContentBuilder
    private var referenceBandMark: some ChartContent {
        if let band = target.referenceBand {
            RectangleMark(
                yStart: .value(String(localized: "med.wirkung.legend.typicalRange"), band.low),
                yEnd: .value(String(localized: "med.wirkung.legend.typicalRange"), band.high)
            )
            .foregroundStyle(HLChartTints.seriesLow.opacity(0.16))
        }
    }

    /// Shaded pause bands — an open pause runs to the latest datum.
    @ChartContentBuilder
    private var pauseMarks: some ChartContent {
        ForEach(markers.pauses) { pause in
            RectangleMark(
                xStart: .value(String(localized: "med.wirkung.legend.pause"), pause.from),
                xEnd: .value(String(localized: "med.wirkung.legend.pause"), pause.to ?? rightEdge ?? pause.from)
            )
            .foregroundStyle(HLText.primary.opacity(0.06))
        }
    }

    @ChartContentBuilder
    private var seriesMarks: some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value(String(localized: "med.wirkung.axis.date"), point.t),
                y: .value(target.label, point.value)
            )
            .foregroundStyle(HLChartTints.series)
            .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineJoin: .round))
            .interpolationMethod(.monotone)

            PointMark(
                x: .value(String(localized: "med.wirkung.axis.date"), point.t),
                y: .value(target.label, point.value)
            )
            .foregroundStyle(HLChartTints.series)
            .symbolSize(24)
        }
    }

    /// Quiet dashed dose-change markers — neutral, no attribution.
    @ChartContentBuilder
    private var doseChangeMarks: some ChartContent {
        ForEach(markers.doseChanges) { change in
            RuleMark(x: .value(String(localized: "med.wirkung.legend.doseChange"), change.at))
                .foregroundStyle(HLChartTints.seriesMid)
                .lineStyle(StrokeStyle(lineWidth: HLChartGrid.thresholdWidth, dash: HLChartGrid.thresholdDash))
        }
    }

    /// The start marker — the ONE accent ("signal-colour only for markers"),
    /// a solid rule labelled "Beginn".
    @ChartContentBuilder
    private var startMark: some ChartContent {
        if let start = markers.start {
            RuleMark(x: .value(String(localized: "med.wirkung.startMarker"), start))
                .foregroundStyle(HLAccent.primary)
                .lineStyle(StrokeStyle(lineWidth: HLChartGrid.thresholdWidth))
                .annotation(position: .top, alignment: .leading, spacing: HLSpace.xxs) {
                    Text("med.wirkung.startMarker")
                        .font(.hlCaption2.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                }
        }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: HLSpace.md) {
            if markers.start != nil {
                EfficacyLegendEntry(titleKey: "med.wirkung.startMarker", style: .solid(HLAccent.primary))
            }
            if !markers.doseChanges.isEmpty {
                EfficacyLegendEntry(titleKey: "med.wirkung.legend.doseChange", style: .dashed(HLChartTints.seriesMid))
            }
            if !markers.pauses.isEmpty {
                EfficacyLegendEntry(titleKey: "med.wirkung.legend.pause", style: .band(HLText.primary.opacity(0.12)))
            }
            if target.referenceBand != nil {
                EfficacyLegendEntry(
                    titleKey: "med.wirkung.legend.typicalRange",
                    style: .band(HLChartTints.seriesLow.opacity(0.22))
                )
            }
            Spacer(minLength: 0)
        }
    }
}

/// One legend swatch + label. `.solid` (start), `.dashed` (dose change),
/// `.band` (pause / typical-range fill).
private struct EfficacyLegendEntry: View {
    enum Style {
        case solid(Color)
        case dashed(Color)
        case band(Color)
    }

    let titleKey: LocalizedStringKey
    let style: Style

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            swatch
            Text(titleKey)
                .font(.hlCaption2)
                .foregroundStyle(HLText.secondary)
        }
    }

    @ViewBuilder
    private var swatch: some View {
        switch style {
        case let .solid(color):
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 2)
        case let .dashed(color):
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 4, height: 2)
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 4, height: 2)
            }
            .frame(width: 14)
        case let .band(color):
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 10)
        }
    }
}

// MARK: - Before / after

/// The before/after-start comparison. When the server marks it `present`, a
/// neutral "Ø before → Ø since — a change of Δ" line + the reading counts;
/// otherwise the server's honest insufficient-data reason. Descriptive only —
/// "change" (Veränderung), never "improvement" / "worse".
private struct EfficacyBeforeAfterCard: View {
    let beforeAfter: MedicationEfficacyDTO.Target.BeforeAfter
    let unit: String?
    let minWeeksPerSide: Int

    var body: some View {
        if beforeAfter.isRenderable,
           let before = beforeAfter.before,
           let after = beforeAfter.after,
           let delta = beforeAfter.delta
        {
            renderable(before: before, after: after, delta: delta)
        } else {
            insufficient
        }
    }

    private func renderable(
        before: MedicationEfficacyDTO.Target.BeforeAfter.Side,
        after: MedicationEfficacyDTO.Target.BeforeAfter.Side,
        delta: MedicationEfficacyDTO.Target.BeforeAfter.Delta
    ) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(summaryText(before: before, after: after, delta: delta))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(countsText(before: before, after: after))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.md)
        .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.sm))
    }

    private var insufficient: some View {
        Text(insufficientText)
            .font(.hlSubhead)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HLSpace.md)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.sm)
                    .strokeBorder(HLColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func summaryText(
        before: MedicationEfficacyDTO.Target.BeforeAfter.Side,
        after: MedicationEfficacyDTO.Target.BeforeAfter.Side,
        delta: MedicationEfficacyDTO.Target.BeforeAfter.Delta
    ) -> String {
        let sign = delta.mean > 0 ? "+" : ""
        return String(
            format: String(localized: "med.wirkung.beforeAfter.summary"),
            formatValue(before.mean),
            formatValue(after.mean),
            "\(sign)\(formatValue(delta.mean))"
        )
    }

    private func countsText(
        before: MedicationEfficacyDTO.Target.BeforeAfter.Side,
        after: MedicationEfficacyDTO.Target.BeforeAfter.Side
    ) -> String {
        String(
            format: String(localized: "med.wirkung.beforeAfter.counts"),
            before.count,
            after.count
        )
    }

    private var insufficientText: String {
        switch beforeAfter.reason {
        case "insufficient_before":
            String(format: String(localized: "med.wirkung.beforeAfter.needBefore"), minWeeksPerSide)
        case "insufficient_after":
            String(format: String(localized: "med.wirkung.beforeAfter.needAfter"), minWeeksPerSide)
        case "no_start":
            String(localized: "med.wirkung.beforeAfter.needStart")
        default:
            String(format: String(localized: "med.wirkung.beforeAfter.needData"), minWeeksPerSide)
        }
    }

    private func formatValue(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0 ... 1)))
        if let unit, !unit.isEmpty { return "\(number) \(unit)" }
        return number
    }
}

// MARK: - Adherence readout

/// The cadence-aware adherence lane, rendered in the med-compliance idiom
/// (`HLSparkline`, like `ComplianceRingCard`): the server's daily rate trend +
/// summed taken/missed counts. Counts are server integers summed for display —
/// NOT a client-recomputed compliance percentage.
private struct EfficacyAdherenceReadout: View {
    let points: [MedicationEfficacyDTO.AdherencePoint]

    private var takenTotal: Int {
        points.reduce(0) { $0 + $1.taken }
    }

    private var expectedTotal: Int {
        points.reduce(0) { $0 + $1.taken + $1.missed }
    }

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text("med.wirkung.adherence.title")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text(captionText)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: HLSpace.sm)
            HLSparkline(values: points.map(\.rate), tint: HLChartTints.seriesMid)
                .frame(width: 96, height: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.md)
        .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.sm))
    }

    private var captionText: String {
        String(
            format: String(localized: "med.wirkung.adherence.caption"),
            takenTotal,
            expectedTotal
        )
    }
}

// MARK: - Retarget control

/// The target picker — pins the metric/lab the medication is tracked against
/// (wired to `PUT /efficacy/target` via the store), plus a "reset to default"
/// item when an override is active. Applies on selection; the store owns the
/// async write + re-fetch, so the section simply repaints when it lands.
private struct EfficacyRetargetControl: View {
    let options: MedicationEfficacyDTO.OverrideOptions
    let isOverride: Bool
    let onSelectTarget: (EfficacyTargetSelection) -> Void

    var body: some View {
        Menu {
            if !options.metrics.isEmpty {
                Section(String(localized: "med.wirkung.retarget.metricsGroup")) {
                    ForEach(options.metrics) { metric in
                        Button(metric.label) { onSelectTarget(.metric(metric.key)) }
                    }
                }
            }
            if !options.biomarkers.isEmpty {
                Section(String(localized: "med.wirkung.retarget.labsGroup")) {
                    ForEach(options.biomarkers) { biomarker in
                        Button(biomarker.label) { onSelectTarget(.lab(biomarker.id)) }
                    }
                }
            }
            if isOverride {
                Divider()
                Button(role: .destructive) { onSelectTarget(.clear) } label: {
                    Label(String(localized: "med.wirkung.retarget.reset"), systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "slider.horizontal.3")
                    .font(.hlIcon(HLIconSize.sm))
                Text("med.wirkung.retarget.label")
                    .font(.hlFootnote)
                Image(systemName: "chevron.down")
                    .font(.hlIcon(HLIconSize.xs))
            }
            .foregroundStyle(HLText.secondary)
        }
    }
}
