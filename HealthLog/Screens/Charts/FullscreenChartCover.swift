import Charts
import SwiftUI

// v0.6.2.9 Y10.8-D1 — fullscreen chart presentation extracted out of
// `ChartDetailScreen.swift` so the parent file stays inside the
// 1 000-line soft cap. The cover re-renders the same per-`MetricKind`
// marks the inline `ChartCard` uses, with the same selection-scrubber
// overlay, so the operator's `selectedDate` carries across when the
// chart is zoomed in. Range picker sits at the bottom so the operator
// can still flip 7d / 30d / 90d while zoomed in. Closing the cover —
// either via the `Fertig` toolbar button or by swiping down — returns
// to the detail view at the same scroll + range state.

struct FullscreenChartCover: View {
    let kind: MetricKind
    // v0.7.1 M-1 — `@Bindable` projection of the shared @Observable store
    // so `$store.range` drives the picker directly, instead of a hand-rolled
    // `Binding(get:set:)` in body that sidesteps SwiftUI's dependency
    // tracking. The cover already shares the parent's store instance.
    @Bindable var store: ChartDetailStore
    @Binding var selectedDate: Date?
    @Environment(\.dismiss) private var dismiss
    /// #115 P2 — plot, axis, callout and audio graph in the account's unit,
    /// glucose pinned to the unit the series arrived in (same as `ChartCard`).
    @Environment(\.unitPreferences) private var settingsUnits
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let series = store.displaySeries, series.points.count >= 2 {
                    chart(for: series)
                        .padding(.horizontal, HLSpace.md)
                        .padding(.vertical, HLSpace.lg)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HLColor.background.ignoresSafeArea())
            // v0.13.1 UX-D4 — the range control is now the SAME floating
            // Liquid-Glass capsule (`HLFloatingPeriodControl`) pinned to the
            // bottom safe-area that every metric page + the Mood screens host,
            // replacing the legacy `HLRangePicker(.bar)`. So the fullscreen zoom
            // cover's range picker matches the surface it zoomed FROM
            // (`InsightsMetricScreen`) instead of reading as a different control.
            .safeAreaInset(edge: .bottom) {
                HLFloatingPeriodControl(selection: $store.range, accessibilityLabelText: "Time range")
            }
            .navigationTitle(kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) { dismiss() }
                        .accessibilityIdentifier("chartDetail.fullscreen.dismiss")
                }
            }
            .sensoryFeedback(.selection, trigger: store.range)
            .sensoryFeedback(.selection, trigger: selectedDate)
        }
    }

    private func chart(for series: MeasurementSeries) -> some View {
        let plotted = store.plotPoints(series.points, units: units)
        return Chart {
            MetricChartContent.marks(
                for: kind,
                points: plotted,
                // v0.14 light-mode walk: refined graphite chart ink (matches
                // the `HLChartTints.series` default — softer than near-black text).
                emphasisTint: HLColor.inkGraphite
            )
            if let selectedDate,
               let selectedPoint = series.points.min(by: {
                   abs($0.at.timeIntervalSince(selectedDate)) < abs($1.at.timeIntervalSince(selectedDate))
               }),
               let plottedPoint = plotted.first(where: { $0.id == selectedPoint.id })
            {
                RuleMark(x: .value("chart.scrubber.selection", selectedPoint.at))
                    .foregroundStyle(HLChartTints.seriesMid)
                    .lineStyle(StrokeStyle(
                        lineWidth: HLChartGrid.thresholdWidth,
                        dash: HLChartGrid.thresholdDash
                    ))
                    .annotation(
                        position: .top,
                        spacing: HLSpace.xs,
                        // v0.11 #23 — fit vertically inside the chart bounds so
                        // the callout never clips above the plot (see HLChartScrubber).
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        // The callout converts the canonical point itself; before
                        // #115 P2 it had no `displayUnit` and printed a converted
                        // lb value next to the fallback "kg".
                        SelectedPointCallout(
                            point: selectedPoint,
                            kind: kind,
                            isPersonalRecord: false,
                            displayUnit: store.displayUnit(units: units)
                        )
                        .environment(\.unitPreferences, units)
                    }
                PointMark(
                    x: .value("chart.scrubber.selection", plottedPoint.at),
                    y: .value("Value", plottedPoint.value)
                )
                .foregroundStyle(HLChartTints.series)
                .symbolSize(160)
                if let secondary = plottedPoint.secondary {
                    PointMark(
                        x: .value("chart.scrubber.selection", plottedPoint.at),
                        y: .value("Diastolic", secondary)
                    )
                    .foregroundStyle(HLChartTints.seriesMid)
                    .symbolSize(160)
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYScale(
            domain: MetricChartMath.logDomain(for: plotted),
            type: store.useLogScale ? .log : .linear
        )
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                    .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisTick()
                    .foregroundStyle(HLText.tertiary)
                AxisValueLabel()
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {
            Text(store.displayUnit(units: units))
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.day().month(.abbreviated))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                    AxisGridLine()
                        .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                }
            }
        }
        .hlAnimation(.snappy(duration: 0.35), value: store.range)
        .accessibilityChartDescriptor(
            FullscreenChartDescriptor(
                descriptor: ChartsAccessibility.makeDescriptor(
                    for: store.accessibilitySeries(units: units),
                    kind: kind,
                    unit: store.displayUnit(units: units)
                )
            )
        )
    }

    /// Fullscreen-chart empty surface — the canonical `HLEmptyState` lockup
    /// (audit-01 C1); the host `Group` already centers it full-bleed.
    private var emptyState: some View {
        HLEmptyState(
            icon: "chart.line.flattrend.xyaxis",
            title: "No data yet",
            message: "Log measurements to see the trend in fullscreen."
        )
        .accessibilityIdentifier("chart.fullscreen.empty")
    }
}

/// Local AX descriptor representable — mirrors the private one inside
/// `ChartDetailScreen.swift`. Two privates can't share, so we keep a
/// tiny parallel struct here.
private struct FullscreenChartDescriptor: AXChartDescriptorRepresentable {
    let descriptor: AXChartDescriptor

    func makeChartDescriptor() -> AXChartDescriptor {
        descriptor
    }

    func updateChartDescriptor(_: AXChartDescriptor) {
        // Static — descriptor rebuilds on every render via `makeChartDescriptor`.
    }
}
