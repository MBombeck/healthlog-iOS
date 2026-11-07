import Charts
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// v0.11 W22-W2 — shared chart-detail building blocks.
//
// `HeroStrip`, `StatsRow` (+ `StatBox`, now in `StatsRow.swift`), `ChartCard` (+ `ChartDescriptor`) were
// lifted verbatim out of `ChartDetailScreen.swift` so the new web-mirror
// `InsightsMetricScreen` can compose the SAME chart block without duplicating
// it. They moved from `private struct` (host-file scope) to internal `struct`
// with NO behavioural change — `ChartDetailScreen` references them unchanged and
// stays byte-for-byte identical in behaviour. The host file keeps the rest of
// its private subviews (`ChartOptionsMenu`, `SourcesRow`, `FindingsList`, …).

// MARK: - Hero strip

struct HeroStrip: View {
    let store: ChartDetailStore
    var matchedNamespace: Namespace.ID? // W-IMPL-MOTION-POLISH destination ns.
    /// A360-5 C-1/C-2 — convert the hero value + flip the unit label to the
    /// user's chosen unit (kg→lb, mmHg→kPa), matching the dashboard. Glucose is
    /// already server-converted on the series payload (passed through).
    @Environment(\.unitPreferences) private var settingsUnits
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// #108 — glucose pinned to the unit the series arrived in.
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    /// T4 — how far the one-line hero value may shrink before it would wrap.
    static let valueMinimumScaleFactor: CGFloat = 0.5

    /// T4 — from the AX text sizes on, the delta chip sits below the value.
    static func stacksDeltaChip(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // 1.4 B2 — the only caller (`lastMeasurementBlock`) mounts the
                // strip only with a latest point, so the empty and spinner
                // branches it used to carry could never show.
                if let latest = store.latestPoint {
                    readyContent(latest: latest)
                }
            }
        }
    }

    @ViewBuilder
    private func readyContent(latest: SeriesPoint) -> some View {
        // v0.14.3 C3 — the delta tick is pinned to the TOP of the value row
        // (`.top` alignment), NOT baseline-aligned to the large-title number.
        // The canonical 30-day status card's classification chip lives in its
        // header row top, so pinning this tick to the top of the Letzte-Messung
        // card's first row puts BOTH ticks at the SAME vertical position across
        // the two stacked cards (operator C3: the ticks must line up).
        // T4 / public #15 — the value never breaks inside the number. A BP pair
        // ("128/93") wrapped into "12 / 8/9 / 3" at a large text size, because
        // the value had no line limit and the delta chip took the row's width.
        // One line, scaled down when needed; from the accessibility sizes on,
        // the chip moves BELOW the value instead of beside it. `AnyLayout` keeps
        // the value's identity (and its matched-geometry zoom) across the switch.
        let stacked = Self.stacksDeltaChip(dynamicTypeSize)
        let row = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.xs))
        row {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                Text(formattedValue(latest)) // W-IMPL-MOTION-POLISH destination ↓
                    .font(.hlMetric(.largeTitle))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    // T4 — shrink (only when it must) rather than wrap.
                    .minimumScaleFactor(Self.valueMinimumScaleFactor)
                    .layoutPriority(1)
                    .matchedTileGeometry(
                        id: DashboardMatchedGeometryID.value(for: store.kind),
                        in: matchedNamespace
                    )
                // A360-5 C-1 — unit-aware label: glucose mg/dL|mmol/L from the
                // server unit-at-source; weight/BP flipped to the user's chosen
                // unit on-device (the value is converted to match).
                Text(store.displayUnit(units: units))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !stacked {
                Spacer(minLength: HLSpace.xs)
            }
            if let change = store.rangeChange {
                // 1.5 VERDICTS — the server's change and verdict when it sends
                // them, else (older server) the own comparison in neutral.
                // A360-5 — the delta + its label both convert for the
                // re-unitable weight/BP families (purely multiplicative; glucose
                // series deltas are already in the user's unit).
                HeroDeltaChip(
                    delta: store.convertDelta(change.delta, units: units),
                    unit: store.displayUnit(units: units),
                    sentiment: change.sentiment,
                    basis: change.basis
                )
                .fixedSize()
            }
        }
        Text(latest.at, format: .dateTime.weekday(.wide).day().month().hour().minute())
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
        SleepSplitCaption(split: store.latestRawMeasurement?.sleepSplit) // #146: night and naps of a sleep day
        // 1.4 B2 — pulse pressure and mean pressure come from this reading, so
        // they sit with it as one line. What they mean, their typical values
        // and the references are in the page's info sheet.
        if store.kind == .bloodPressure,
           let readout = BPDerivedReadout.derive(systolic: latest.value, diastolic: latest.secondary)
        {
            Text("insights.bp.derived.line \(readout.pulsePressure) \(readout.meanArterialPressure)")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.metric.bp.derived")
        }
        // v0.7.0 W-API-RENDER — server-computed 7/30/90-day regression
        // slopes rendered as direction chips. The server already decides
        // up/down/stable; we only translate the glyph + the window label.
        let slopes = store.trendSlopes
        if !slopes.isEmpty {
            TrendSlopeRow(slopes: slopes)
        }
        // v0.7.0 W-API-RENDER — "Vor 1 Jahr" baseline + delta, sourced
        // verbatim from `avg30LastYear`. Hidden when the server has no
        // year-old window (user onboarded < 1y ago).
        if let lastYear = store.avg30LastYear {
            // A360-5 — the year-over-year baseline + delta come from the
            // analytics SUMMARY (canonical for every family, incl. glucose), so
            // convert both and use the summary label.
            YearOverYearRow(
                baseline: store.convertSummaryValue(lastYear, units: units),
                delta: store.deltaVsLastYear.map { store.convertSummaryValue($0, units: units) },
                unit: store.summaryDisplayUnit(units: units)
            )
        }
    }

    /// A360-5 C-1/C-2 — the hero value in the user's chosen unit. BP converts +
    /// honours the kPa 1-decimal branch (was hard-rounded to Int); weight
    /// converts to lb; glucose is already server-converted on the series payload
    /// (passed through). mmHg / default-unit users are unchanged.
    private func formattedValue(_ point: SeriesPoint) -> String {
        if let secondary = point.secondary {
            return MetricValueFormatter.formatBloodPressure(
                systolic: point.value,
                diastolic: secondary,
                units: units
            )
        }
        return MetricValueFormatter.formatScalar(
            point.value,
            kind: store.kind,
            units: units,
            glucose: .seriesPreConvertedGlucose
        )
    }
}

// MARK: - Chart card with selected-point overlay

struct ChartCard: View {
    /// v0.11 W56 (#55) — a reload must never look frozen. While `store.isLoading`
    /// is true AND the card is already showing a populated chart (range change,
    /// not first paint), the chart is gently dimmed and a small inline progress
    /// affordance fades in over it, so moving the time-range control reads as
    /// "updating…" rather than a stuck graph. Reduce-motion swaps the fade for an
    /// instant cut.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A360-5 C-1 — the scrub callout's unit label flips to the user's chosen
    /// unit (kg→lb, mmHg→kPa); the callout converts the value itself.
    @Environment(\.unitPreferences) private var settingsUnits
    /// #108 — glucose pinned to the unit the series arrived in.
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    let kind: MetricKind
    let store: ChartDetailStore
    @Binding var selectedDate: Date?
    /// v0.12 W8-9 — native horizontal pan position. Bound to
    /// `chartScrollPosition(x:)` so the scroll offset survives re-renders. Swift
    /// Charts clamps the seed into the data domain on first paint and updates it
    /// as the user pans; `.now` is a harmless initial leading anchor.
    @State private var scrollPositionX: Date = .now
    /// C-10: user-picked chart emphasis color (`SettingsStore.preferredTint`).
    /// Forwarded into `MetricChartContent.marks(...)` as `emphasisTint` —
    /// overrides the per-metric Dracula default on the primary LineMark only.
    let emphasisTint: Color
    /// W3b C1 — zoom-morph namespace; the data-bearing card is the source.
    let zoomNamespace: Namespace.ID
    /// W22-W2 — the source id for the `.zoom` transition. ChartDetailScreen and
    /// InsightsMetricScreen each own a distinct namespace + id pair so the two
    /// fullscreen covers never collide.
    let zoomSourceID: String
    /// v0.6.2.9 Y10.8-D1 — tap on the chart card lifts it to a
    /// fullscreen cover. Only the data-bearing branch wires the tap.
    let onTapChart: () -> Void
    /// 1.4 B2 — the "vs prior month" delta reads the drawn series, so it is the
    /// chart card's one caption line instead of a loose line below the page.
    var rangeDelta: MetricRangeDelta?
    /// 1.5 LAB-LINES — the card's line above the chart (the usual range from
    /// `coach-read`) and, in place of the change line, what the chart is
    /// narrowed to (a part of the day). `nil` for none.
    var headline: String?
    var caption: String?

    var body: some View {
        // DASHBOARD-CHARTS-BUG-FIX (2026-05-16): `series` is the chart's
        // ground truth — render whenever it carries >= 2 points, regardless
        // of `dataState`. 1.4 B1: the rest is ``ChartCardPhase``: spinner
        // while a load runs, the error face after a failed one, and „Noch
        // keine Daten" only once a load has finished empty. The old 3 s
        // timeout that degraded a slow load to „Noch keine Daten" is gone.
        switch ChartCardPhase.resolve(
            pointCount: store.chartCardPoints.count,
            dataState: store.dataState,
            isLoading: store.chartCardIsLoading,
            hasError: store.chartCardHasError
        ) {
        case .chart:
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if let headline {
                        cardLine(headline, identifier: "chart.card.headline")
                    }
                    chartView
                        .frame(height: HLChartStyle.heightRegular)
                        // #55 — dim the populated chart while a reload is in flight
                        // so a range change reads as "updating", never frozen.
                        .opacity(store.chartCardIsLoading ? 0.45 : 1)
                        .overlay {
                            if store.chartCardIsLoading {
                                reloadAffordance
                            }
                        }
                        .hlAnimation(.easeInOut(duration: 0.2), value: store.chartCardIsLoading)
                        // The dimmed chart is decorative during a reload — let
                        // VoiceOver announce the loading state instead of reading
                        // out the stale (about-to-change) data series.
                        .accessibilityValue(store.chartCardIsLoading ? Text(String(localized: "Loading")) : Text(""))
                        // A11Y (1.5) — the chart is what opens full screen. On
                        // the card the button trait reached every line in it,
                        // so the headline and the comparison line read as
                        // buttons too, each with a hit area of one text line.
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text(String(localized: "Double-tap to open the chart full screen")))
                    if let caption {
                        cardLine(caption, identifier: "chart.card.caption")
                    } else {
                        rangeDelta
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapChart() }
            // W3b C1 — zoom-morph source for the fullscreen cover (iOS 18+).
            .matchedTransitionSource(id: zoomSourceID, in: zoomNamespace)
        case .singlePoint:
            // Series landed but only one point — Apple-Health "Need more
            // data" copy. Independent of dataState (which may still be
            // .loading at this moment).
            InsufficientDataCard(kind: kind, hasOnePoint: true)
        case .empty:
            // The load finished and confirmed there is nothing to draw.
            InsufficientDataCard(kind: kind, hasOnePoint: false)
        case .failed:
            // 1.4 B1: a failed load says so, with the shared retry face,
            // instead of passing for an empty history.
            HLCard {
                HLRetryUnavailableView {
                    await store.load()
                    await store.loadPartOfDay()
                }
            }
            .accessibilityIdentifier("chart.card.failed")
        case .loading:
            // A load is in flight (or about to start). The store settles
            // `isLoading` and `dataState` on every exit path, so this spins
            // exactly as long as the network takes.
            HLCard {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: HLChartStyle.heightRegular)
            }
        }
    }

    /// 1.5 LAB-LINES — one quiet line inside the card.
    private func cardLine(_ text: String, identifier: String) -> some View {
        Text(verbatim: text)
            .font(.hlSubhead)
            .foregroundStyle(HLText.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    /// #55 — the in-chart "updating" affordance shown over the dimmed populated
    /// chart during a reload. A bare `ProgressView` in a glass-y capsule, so the
    /// operator gets an unmistakable "it's working" cue when they move the
    /// time-range control. Motion (the spinner) is the system `ProgressView`'s
    /// own and already collapses under reduce-motion; the `reduceMotion` check
    /// only governs the surrounding fade applied at the call-site.
    private var reloadAffordance: some View {
        ProgressView()
            .controlSize(.regular)
            .padding(HLSpace.md)
            .hlGlassEffect(in: Capsule(), fallback: HLSurface.secondary)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityHidden(true)
    }

    /// Renders the populated chart. `body` already gates on `series.points.count
    /// >= 2`, so we force-unwrap the series here — the precondition is local.
    @ViewBuilder
    private var chartView: some View {
        let points = store.chartCardPoints
        // #115 P2 — the plot, the y-axis and the audio graph read in the
        // account's unit (`plotPoints`), the same unit as the hero and the
        // stats row. The scrub callout still receives the canonical point
        // (`points`) because it converts the value itself.
        let plotted = store.plotPoints(points, units: units)
        if points.count >= 2 {
            Chart {
                // #135 — the server's reference lines (v1.43) under the series.
                MetricChartContent.marks(
                    for: kind,
                    points: plotted,
                    emphasisTint: emphasisTint,
                    references: store.referenceLineMarks(units: units)
                )

                if let selectedDate, let selectedPoint = nearestPoint(to: selectedDate, in: points),
                   let plottedPoint = plotted.first(where: { $0.id == selectedPoint.id })
                {
                    // Apple-Health-style scrubber: dashed vertical RuleMark
                    // anchored at the nearest point's x, with the floating
                    // callout pinned to top. The dashed pattern reads as
                    // "interactive overlay" rather than a data series.
                    // T2-3: tint routes through `HLChartTints.seriesMid`
                    // (single accent at 70% opacity) — visually identical
                    // to the previous `.purple.opacity(0.55)` but sourced
                    // from the locked Theme-2.0 chart palette so any
                    // future accent swap propagates here automatically.
                    RuleMark(x: .value("chart.scrubber.selection", selectedPoint.at))
                        .foregroundStyle(HLChartTints.seriesMid)
                        .lineStyle(StrokeStyle(
                            lineWidth: HLChartGrid.thresholdWidth,
                            dash: HLChartGrid.thresholdDash
                        ))
                        // v0.11 #23 — y:.fit(to:.chart) so the scrub callout never clips above the plot.
                        .annotation(
                            position: .top,
                            spacing: HLSpace.xs,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            SelectedPointCallout(
                                point: selectedPoint,
                                kind: kind,
                                isPersonalRecord: isPersonalRecord(selectedPoint, in: points),
                                displayUnit: store.displayUnit(units: units)
                            )
                            // #108 — the callout formats with the chart's units.
                            .environment(\.unitPreferences, units)
                        }
                    // Highlighted point marker — emphasizes the value the
                    // callout describes. Larger than the per-metric symbols.
                    PointMark(
                        x: .value("chart.scrubber.selection", plottedPoint.at),
                        y: .value("Value", plottedPoint.value)
                    )
                    .foregroundStyle(HLChartTints.series)
                    .symbolSize(120)
                    if let secondary = plottedPoint.secondary {
                        // BP — emphasize both lines under the cursor. The
                        // diastolic dot matches the BP secondary-line tint
                        // (single accent at 40% opacity, 1.4 B4).
                        PointMark(
                            x: .value("chart.scrubber.selection", selectedPoint.at),
                            y: .value("Diastolic", secondary)
                        )
                        .foregroundStyle(HLChartTints.seriesLow)
                        .symbolSize(120)
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            // v0.12 W8-9 — native horizontal timeline panning (iOS 17+, ships
            // to the iOS 18 floor, no #available). The visible domain is the
            // full data span so the default framing is unchanged (whole series
            // visible, no regression to the #56 cache-first first-paint), while
            // the scroll infrastructure + bound position let the user pan
            // back/forward when a future tighter visible-domain lands. The
            // `chartXSelection` scrubber stays wired and coexists — a drag-hold
            // scrubs, a drag-pan scrolls.
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: Self.visibleDomainLength(for: points))
            .chartScrollPosition(x: $scrollPositionX)
            // Y-axis: log mode is opt-in via the chart-toolbar menu. Log scale
            // is undefined for non-positive values — we clamp the domain lower
            // bound to a tiny positive epsilon so a single 0-reading doesn't
            // crash the chart. Linear mode falls through to the chart's
            // default domain (no `.chartYScale` modifier on that branch).
            .chartYScale(
                domain: MetricChartMath.logDomain(for: plotted, including: store.plotReferenceLines(units: units)),
                type: store.useLogScale ? .log : .linear
            )
            // T2-3 (Theme-2.0): axis grid + labels follow the Tonal-Mono
            // subtle treatment — ~10% gridline opacity, hairline 0.5pt
            // stroke, ~40% label opacity. Tokens locked in `HLChartGrid`.
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
                // W-B187 (#29) — server-resolved unit (glucose mg/dL | mmol/L);
                // #115 P2 — the account's unit for every client-converted family.
                Text(store.displayUnit(units: units))
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
            }
            // 1.4 B4 — the app's one date-axis rule (format by span, the last
            // label ends at its tick so it is never cut).
            .chartXAxis { ChartDateAxis.marks(for: plotted.map(\.at)) }
            // Honour reduce-motion via .hlAnimation (audit M16). The Chart
            // morphs new line shapes between range changes — `.snappy` feels
            // right for ~350ms of y-rescale + line draw.
            .hlAnimation(.snappy(duration: 0.35), value: store.range)
            .accessibilityChartDescriptor(
                ChartDescriptor(
                    descriptor: ChartsAccessibility.makeDescriptor(
                        for: store.chartCardAccessibilitySeries(units: units),
                        kind: kind,
                        unit: store.displayUnit(units: units)
                    )
                )
            )
        }
        // No `else` branch — body already routes the < 2-points / loading
        // cases to InsufficientDataCard / ProgressView at the card-shell
        // boundary, so this view is only mounted when data is present.
    }

    /// v0.12 W8-9 — visible-domain length (seconds) for
    /// `chartScrollableAxes`. Returns the full span of the series (slightly
    /// padded) so the default render shows every point — panning is available
    /// but the framing is identical to the pre-W8-9 chart. A minimum of one day
    /// guards the single-cluster case so the domain is never zero.
    static func visibleDomainLength(for points: [SeriesPoint]) -> TimeInterval {
        guard let first = points.first?.at, let last = points.last?.at else {
            return 24 * 60 * 60
        }
        let span = last.timeIntervalSince(first)
        let padded = span * 1.05
        return max(padded, 24 * 60 * 60)
    }

    private func nearestPoint(to date: Date, in points: [SeriesPoint]) -> SeriesPoint? {
        points.min(by: { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) })
    }

    private func isPersonalRecord(_ point: SeriesPoint, in points: [SeriesPoint]) -> Bool {
        // PR = window-min for "lower-is-better" metrics, window-max otherwise.
        // Conservative default: max for weight/glucose/BP would actually be a *worst*,
        // so we treat PR as min for those domains.
        let isLowerBetter = switch kind {
        case .weight, .glucose, .bloodPressure, .bodyFat, .bodyTemperature: true
        default: false
        }
        let extreme = isLowerBetter
            ? points.min(by: { $0.value < $1.value })?.value
            : points.max(by: { $0.value < $1.value })?.value
        return extreme.map { abs($0 - point.value) < 0.0001 } ?? false
    }
}

/// `accessibilityChartDescriptor` (iOS 17+) wants a representable, not the raw descriptor.
struct ChartDescriptor: AXChartDescriptorRepresentable {
    let descriptor: AXChartDescriptor

    func makeChartDescriptor() -> AXChartDescriptor {
        descriptor
    }

    func updateChartDescriptor(_: AXChartDescriptor) {
        // Static — descriptor rebuilds on every render via `makeChartDescriptor`.
    }
}
