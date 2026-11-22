import Charts
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// Shared chart-detail building blocks.
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
    /// Glucose pinned to the unit the series arrived in.
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    /// How far the one-line hero value may shrink before it would wrap.
    static let valueMinimumScaleFactor: CGFloat = 0.5

    /// Day, date and time of the latest reading, the weekday in the case
    /// it takes inside a sentence.
    static var dateFormat: Date.FormatStyle {
        Date.FormatStyle(capitalizationContext: .middleOfSentence).weekday(.wide).day().month().hour().minute()
    }

    /// From the AX text sizes on, the delta chip sits below the value.
    static func stacksDeltaChip(_ size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // The only caller (`lastMeasurementBlock`) mounts the
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
        // The delta tick is pinned to the TOP of the value row
        // (`.top` alignment), NOT baseline-aligned to the large-title number.
        // The canonical 30-day status card's classification chip lives in its
        // header row top, so pinning this tick to the top of the Letzte-Messung
        // card's first row puts BOTH ticks at the SAME vertical position across
        // the two stacked cards (operator C3: the ticks must line up).
        // The value never breaks inside the number. A BP pair
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
                // The page's one large figure, in the hero fonts of
                // `HLValueText`; the value arrives formatted (pressure pair,
                // converted unit), so the text sets those fonts itself.
                Text(formattedValue(latest)) // W-IMPL-MOTION-POLISH destination ↓
                    .font(HLValueSize.hero.numberFont)
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    // Shrink (only when it must) rather than wrap.
                    .minimumScaleFactor(Self.valueMinimumScaleFactor)
                    .layoutPriority(1)
                    .matchedTileGeometry(
                        id: DashboardMatchedGeometryID.value(for: store.kind),
                        in: matchedNamespace
                    )
                // Unit-aware label: glucose mg/dL|mmol/L from the
                // server unit-at-source; weight/BP flipped to the user's chosen
                // unit on-device (the value is converted to match).
                // A duration ("7 Std. 12 Min.") names its units itself.
                let unit = MetricDurationFormat.unit(store.displayUnit(units: units), kind: store.kind)
                if !unit.isEmpty {
                    Text(unit)
                        .font(HLValueSize.hero.unitFont)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if !stacked {
                Spacer(minLength: HLSpace.xs)
            }
            if let change = store.rangeChange {
                // 1.5 VERDICTS — the server's change and verdict when it sends
                // them, else (older server) the own comparison in neutral.
                // The delta + its label both convert for the
                // re-unitable weight/BP families (purely multiplicative; glucose
                // series deltas are already in the user's unit).
                HeroDeltaChip(
                    delta: store.displayDelta(of: change, units: units),
                    unit: store.displayUnit(of: change, units: units),
                    sentiment: change.sentiment,
                    basis: change.basis,
                    kind: store.kind,
                    symbol: change.symbol
                )
                .fixedSize()
            }
        }
        // The weekday as inside a sentence: "zondag" in Dutch, like the
        // start page, never "Zondag".
        Text(latest.at, format: Self.dateFormat)
            .hlText(.rowSubtitle)
        SleepSplitCaption(split: store.latestRawMeasurement?.sleepSplit) // Night and naps of a sleep day
        // Pulse pressure and mean pressure come from this reading, so
        // they sit with it as one line. What they mean, their typical values
        // and the references are in the page's info sheet.
        if store.kind == .bloodPressure,
           let readout = BPDerivedReadout.derive(systolic: latest.value, diastolic: latest.secondary)
        {
            Text("insights.bp.derived.units \(readout.pulsePressure) \(readout.meanArterialPressure)")
                .hlText(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.metric.bp.derived")
        }
        // "Vor 1 Jahr" baseline + delta, sourced
        // verbatim from `avg30LastYear`. Hidden when the server has no
        // year-old window (user onboarded < 1y ago).
        if let lastYear = store.avg30LastYear {
            // The year-over-year baseline + delta come from the
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
        if let duration = MetricDurationFormat.text(point.value, kind: store.kind) {
            return duration
        }
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

// MARK: - The line under the chart

/// What the chart card shows on its line under the chart: what the chart is
/// narrowed to, else the comparison with the period before, else an empty
/// line of the same height.
enum ChartCardFootLine {
    case caption(String)
    case delta(MetricRangeDelta)
    case reserved

    static func resolve(caption: String?, delta: MetricRangeDelta?) -> ChartCardFootLine {
        if let caption { return .caption(caption) }
        if let delta, MetricRangeDelta.resolve(delta.source) != nil { return .delta(delta) }
        return .reserved
    }

    /// Whether the line is the empty placeholder.
    var isReserved: Bool {
        if case .reserved = self { return true }
        return false
    }
}

// MARK: - Chart card with selected-point overlay

struct ChartCard: View {
    /// A reload must never look frozen. While `store.isLoading`
    /// is true AND the card is already showing a populated chart (range change,
    /// not first paint), the chart is gently dimmed and a small inline progress
    /// affordance fades in over it, so moving the time-range control reads as
    /// "updating…" rather than a stuck graph. Reduce-motion swaps the fade for an
    /// instant cut.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The scrub callout's unit label flips to the user's chosen
    /// unit (kg→lb, mmHg→kPa); the callout converts the value itself.
    @Environment(\.unitPreferences) private var settingsUnits
    /// The value axis keeps the system's fewer ticks at the accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Glucose pinned to the unit the series arrived in.
    private var units: UnitPreferences {
        store.effectiveUnits(settingsUnits)
    }

    let kind: MetricKind
    let store: ChartDetailStore
    @Binding var selectedDate: Date?
    /// User-picked chart emphasis color (`SettingsStore.preferredTint`).
    /// Forwarded into `MetricChartContent.marks(...)` as `emphasisTint` —
    /// overrides the per-metric Dracula default on the primary LineMark only.
    let emphasisTint: Color
    /// Zoom-morph namespace; the data-bearing card is the source.
    let zoomNamespace: Namespace.ID
    /// The source id for the `.zoom` transition. ChartDetailScreen and
    /// InsightsMetricScreen each own a distinct namespace + id pair so the two
    /// fullscreen covers never collide.
    let zoomSourceID: String
    /// v0.6.2.9 Y10.8-D1 — tap on the chart card lifts it to a
    /// fullscreen cover. Only the data-bearing branch wires the tap.
    let onTapChart: () -> Void
    /// The "vs prior month" delta reads the drawn series, so it is the
    /// chart card's one caption line instead of a loose line below the page.
    var rangeDelta: MetricRangeDelta?
    /// The card's line above the chart (the usual range from
    /// `coach-read`) and, in place of the change line, what the chart is
    /// narrowed to (a part of the day). `nil` for none.
    var headline: String?
    var caption: String?
    /// The period's mean and span over the chart (``MetricPeriodSummary``),
    /// `nil` for none.
    var summary: MetricPeriodSummary.Model?

    /// The card's width and the visible height of the page, for the chart
    /// height of a wide window (``MetricChartHeight``).
    @State private var cardWidth: CGFloat = 0

    var body: some View {
        // DASHBOARD-CHARTS-BUG-FIX (2026-05-16): `series` is the chart's
        // ground truth — render whenever it carries >= 2 points, regardless
        // of `dataState`. The rest is ``ChartCardPhase``: spinner
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
                    if let summary {
                        MetricPeriodSummary(summary: summary)
                    }
                    if let headline {
                        cardLine(headline, identifier: "chart.card.headline")
                    }
                    if kind == .bloodPressure {
                        BloodPressureChartLegend()
                    }
                    chartView
                        // A wide window gives the chart a share of the
                        // visible height; the phone keeps the fixed height.
                        .containerRelativeFrame(.vertical) { length, _ in
                            MetricChartHeight.height(visibleHeight: length, width: cardWidth)
                        }
                        // Dim the populated chart while a reload is in flight
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
                    switch ChartCardFootLine.resolve(caption: caption, delta: rangeDelta) {
                    case let .caption(text):
                        cardLine(text, identifier: "chart.card.caption")
                    case let .delta(delta):
                        delta
                    case .reserved:
                        // No comparison for this metric or period: the line
                        // stays empty, so every chart card has one height.
                        Text(verbatim: " ")
                            .hlText(.rowSubtitle)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    if let capLimit = store.rawChartCapLimit {
                        cardLine(String(localized: "chart.card.rawCapped \(capLimit)"), identifier: "chart.card.rawCapped")
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
            .contentShape(Rectangle())
            .onTapGesture { onTapChart() }
            // One container with a name, so a UI test finds the card that
            // opens full screen instead of tapping where it ought to be.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chart.card")
            // Zoom-morph source for the fullscreen cover (iOS 18+).
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
            // A failed load says so, with the shared retry face,
            // instead of passing for an empty history.
            HLCard {
                HLErrorState {
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

    /// The value domain of the plotted points, the one rule for the card
    /// and the full screen.
    private func valueDomain(_ plotted: [SeriesPoint]) -> ClosedRange<Double> {
        MetricChartScale.valueDomain(
            points: plotted,
            references: store.plotReferenceLines(units: units),
            kind: kind,
            unit: store.displayUnit(units: units),
            useLog: store.useLogScale
        )
    }

    /// One quiet line inside the card.
    private func cardLine(_ text: String, identifier: String) -> some View {
        Text(verbatim: text)
            .hlText(.factLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    /// The in-chart "updating" affordance shown over the dimmed populated
    /// chart during a reload. A bare `ProgressView` in a glass-y capsule, so the
    /// operator gets an unmistakable "it's working" cue when they move the
    /// time-range control. Motion (the spinner) is the system `ProgressView`'s
    /// own and already collapses under reduce-motion; the `reduceMotion` check
    /// only governs the surrounding fade applied at the call-site.
    private var reloadAffordance: some View {
        ProgressView()
            .controlSize(.regular)
            .padding(HLSpace.md)
            // A floating pill over the dimmed chart, not a card surface.
            // swiftlint:disable:next hl_no_glass_in_content
            .hlGlassEffect(in: Capsule(), fallback: HLSurface.secondary)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityHidden(true)
    }

    /// Renders the populated chart. `body` already gates on `series.points.count
    /// >= 2`, so we force-unwrap the series here — the precondition is local.
    @ViewBuilder
    private var chartView: some View {
        let points = store.chartCardPoints
        // The plot, the y-axis and the audio graph read in the
        // account's unit (`plotPoints`), the same unit as the hero and the
        // stats row. The scrub callout still receives the canonical point
        // (`points`) because it converts the value itself.
        let plotted = store.plotPoints(points, units: units)
        if points.count >= 2 {
            Chart {
                // The series, then the server's reference lines (v1.43), so
                // their labels stand on top of the line.
                MetricChartContent.marks(
                    for: kind,
                    points: plotted,
                    emphasisTint: emphasisTint,
                    references: store.referenceLineMarks(units: units),
                    bands: MetricTargetBand.bands(from: store.plotReferenceLines(units: units))
                )

                // The app's one scrubber: dashed rule, emphasised dot (a second
                // one on the diastolic line), the callout pinned to the top.
                // The plot snaps on the converted points; the callout gets the
                // canonical point back, because it converts the value itself.
                HLChartScrubber.marks(
                    selectedDate: selectedDate,
                    in: plotted,
                    date: \.at,
                    value: \.value,
                    secondary: \.secondary
                ) { plottedPoint in
                    SelectedPointCallout(
                        point: Self.canonicalPoint(for: plottedPoint, in: points),
                        kind: kind,
                        isPersonalRecord: isPersonalRecord(Self.canonicalPoint(for: plottedPoint, in: points), in: points),
                        displayUnit: store.displayUnit(units: units)
                    )
                    // The callout formats with the chart's units.
                    .environment(\.unitPreferences, units)
                }
            }
            // Selection, the selection haptic and the VoiceOver reading of
            // the snapped point.
            .hlChartScrub($selectedDate) { date in
                scrubAnnouncement(at: date, in: points)
            }
            // The date axis spans the chosen period, not only the readings
            // in it: three readings under "M" stand where they fall in the
            // month. No horizontal panning, so a vertical swipe over the card
            // scrolls the page.
            .chartXScale(domain: xDomain(for: plotted))
            .chartYScale(domain: valueDomain(plotted), type: store.useLogScale ? .log : .linear)
            // Values on the leading edge with the account's unit above them
            // (glucose mg/dL | mmol/L from the server), dates underneath.
            .hlChartAxes(
                dates: [xDomain(for: plotted).lowerBound, xDomain(for: plotted).upperBound],
                unit: MetricDurationFormat.axisUnit(store.displayUnit(units: units), kind: kind),
                values: MetricChartScale.axisValues(
                    domain: valueDomain(plotted),
                    kind: kind,
                    useLog: store.useLogScale,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ),
                label: MetricDurationFormat.isDuration(kind) ? { MetricDurationFormat.axisLabel(hours: $0) } : nil
            )
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

    /// The chosen period up to now (``MetricChartScale/xDomain(for:dates:now:calendar:)``).
    private func xDomain(for points: [SeriesPoint]) -> ClosedRange<Date> {
        MetricChartScale.xDomain(for: store.range, dates: points.map(\.at), now: .now)
            ?? MetricChartScale.dataDomain(points.map(\.at))
    }

    /// The canonical point behind a plotted (unit-converted) one; both share
    /// the id. Falls back to the plotted point for an unconverted series.
    static func canonicalPoint(for plotted: SeriesPoint, in points: [SeriesPoint]) -> SeriesPoint {
        points.first(where: { $0.id == plotted.id }) ?? plotted
    }

    /// What VoiceOver says when the scrub snaps to a new point: the same
    /// date, value and unit the callout shows.
    private func scrubAnnouncement(at date: Date, in points: [SeriesPoint]) -> String? {
        guard let point = HLChartScrubber.nearest(to: date, in: points, date: \.at) else { return nil }
        return HLScrubCallout.spokenText(
            title: HLSeriesPointCallout.title(for: point.at),
            value: HLSeriesPointCallout.value(of: point, kind: kind, units: units),
            unit: store.displayUnit(units: units),
            marksRecord: isPersonalRecord(point, in: points)
        )
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

/// The key of the blood pressure chart: the shape of each series, in the
/// tone it is drawn in. Read before the chart, so the two lines are told
/// apart without colour.
struct BloodPressureChartLegend: View {
    var body: some View {
        HStack(spacing: HLSpace.md) {
            entry(symbol: "circle.fill", tint: HLChartTints.series, title: "insights.bp.stats.systolic")
            entry(symbol: "diamond.fill", tint: HLChartTints.seriesLow, title: "insights.bp.stats.diastolic")
        }
        .accessibilityHidden(true)
    }

    private func entry(symbol: String, tint: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.xs))
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(title)
                .hlText(.chartMark)
        }
    }
}
