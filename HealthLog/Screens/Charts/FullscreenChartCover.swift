import Charts
import SwiftUI

// v0.6.2.9 Y10.8-D1 — fullscreen chart presentation extracted out of
// `ChartDetailScreen.swift` so the parent file stays inside the
// 1 000-line soft cap. The cover re-renders the same per-`MetricKind`
// marks the inline `ChartCard` uses, with the same selection-scrubber
// overlay, so the operator's `selectedDate` carries across when the
// chart is zoomed in. The period choice sits right above the chart so the
// operator can still flip the range while zoomed in. Closing the cover (the X on
// the leading edge, or a swipe down) returns to the detail view at the
// same scroll and range state.

struct FullscreenChartCover: View {
    let kind: MetricKind
    // `@Bindable` projection of the shared @Observable store
    // so `$store.range` drives the picker directly, instead of a hand-rolled
    // `Binding(get:set:)` in body that sidesteps SwiftUI's dependency
    // tracking. The cover already shares the parent's store instance.
    @Bindable var store: ChartDetailStore
    @Binding var selectedDate: Date?
    /// Lets the phone turn while the cover is up and brings it back upright
    /// when it goes. The scene's orientation policy in the app; a test hands
    /// in a recorder.
    var allowsLandscape: @MainActor (Bool) -> Void = FullscreenChartCover.applyOrientationPolicy
    /// Plot, axis, callout and audio graph in the account's unit,
    /// glucose pinned to the unit the series arrived in (same as `ChartCard`).
    @Environment(\.unitPreferences) private var settingsUnits
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    var body: some View {
        // The sheet scaffold gives the cover its bar: the title, the X on the
        // leading edge and nothing to confirm, like every view that only shows.
        HLSheetScaffold(
            verbatim: kind.displayName,
            size: .cover,
            closeIdentifier: "chartDetail.fullscreen.dismiss"
        ) {
            VStack(spacing: HLSpace.md) {
                Group {
                    // Same points as the chart card it zoomed from (`chartCardPoints`):
                    // kinds without a server series (skin temperature, walking
                    // speed) draw from the raw readings there, so reading only
                    // `chartCardSeries` here showed "no measurements" over a
                    // drawn card.
                    if store.chartCardPoints.count >= 2 {
                        chart(for: store.chartCardPoints)
                            .padding(.horizontal, HLSpace.md)
                            .padding(.bottom, HLLayout.cardInset)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, HLSpace.sm)
            // The same floating period bar as the metric page it zoomed from,
            // so the two read as one control.
            .hlPeriodBar(selection: $store.range, label: "Time range")
        }
        // The one place the phone may turn: across, the chart takes the
        // whole width (the plot has only side padding and two date labels, so
        // the time axis widens instead of crowding). Leaving the cover turns
        // the app upright again.
        .onAppear { allowsLandscape(true) }
        .onDisappear { allowsLandscape(false) }
    }

    /// The scene policy behind ``allowsLandscape``. The scene asks for its
    /// orientations only from iOS 27 on; before that the plist holds.
    static func applyOrientationPolicy(_ allowed: Bool) {
        if #available(iOS 27.0, *) { OrientationPolicy.allowLandscape(allowed) }
    }

    private func chart(for points: [SeriesPoint]) -> some View {
        let plotted = store.plotPoints(points, units: units)
        let xDomain = MetricChartScale.xDomain(for: store.range, dates: plotted.map(\.at), now: .now)
            ?? MetricChartScale.dataDomain(plotted.map(\.at))
        return Chart {
            MetricChartContent.marks(
                for: kind,
                points: plotted,
                // v0.14 light-mode walk: refined graphite chart ink (matches
                // the `HLChartTints.series` default — softer than near-black text).
                emphasisTint: HLColor.inkGraphite,
                references: store.referenceLineMarks(units: units),
                bands: MetricTargetBand.bands(from: store.plotReferenceLines(units: units))
            )
            // The same scrubber as the card it zoomed from. The callout
            // converts the canonical point itself.
            HLChartScrubber.marks(
                selectedDate: selectedDate,
                in: plotted,
                date: \.at,
                value: \.value,
                secondary: \.secondary
            ) { plottedPoint in
                SelectedPointCallout(
                    point: ChartCard.canonicalPoint(for: plottedPoint, in: points),
                    kind: kind,
                    isPersonalRecord: false,
                    displayUnit: store.displayUnit(units: units)
                )
                .environment(\.unitPreferences, units)
            }
        }
        .hlChartScrub($selectedDate)
        // The same scales as the card it zoomed from: the chosen period
        // across, grid-aligned values with room above.
        .chartXScale(domain: xDomain)
        .chartYScale(
            domain: yDomain(for: plotted),
            type: store.useLogScale ? .log : .linear
        )
        .hlChartAxes(
            dates: [xDomain.lowerBound, xDomain.upperBound],
            unit: MetricDurationFormat.axisUnit(store.displayUnit(units: units), kind: kind),
            values: MetricChartScale.axisValues(
                domain: yDomain(for: plotted),
                kind: kind,
                useLog: store.useLogScale,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            ),
            label: MetricDurationFormat.isDuration(kind) ? { MetricDurationFormat.axisLabel(hours: $0) } : nil
        )
        .hlAnimation(.snappy(duration: 0.35), value: store.range)
        .accessibilityChartDescriptor(
            FullscreenChartDescriptor(
                descriptor: ChartsAccessibility.makeDescriptor(
                    for: store.chartCardAccessibilitySeries(units: units),
                    kind: kind,
                    unit: store.displayUnit(units: units)
                )
            )
        )
    }

    /// The same value scale as the card (``MetricChartScale/valueDomain``).
    private func yDomain(for plotted: [SeriesPoint]) -> ClosedRange<Double> {
        MetricChartScale.valueDomain(
            points: plotted,
            references: store.plotReferenceLines(units: units),
            kind: kind,
            unit: store.displayUnit(units: units),
            useLog: store.useLogScale
        )
    }

    /// Fullscreen-chart empty surface — the canonical `HLEmptyState` lockup
    /// (audit-01 C1); the host `Group` already centers it full-bleed. The cover
    /// opens only on a drawn chart, so it is empty only after a range change
    /// inside it: the title names the range, not a missing history.
    private var emptyState: some View {
        HLEmptyState(icon: "chart.line.flattrend.xyaxis", title: "No measurements in the selected range")
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
