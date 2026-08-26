import Charts
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

// v0.11 W22-W2 — shared chart-detail building blocks.
//
// `HeroStrip`, `StatsRow` (+ `StatBox`), `ChartCard` (+ `ChartDescriptor`) were
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
    // A360-5 C-1/C-2 — convert the hero value + flip the unit label to the
    // user's chosen unit (kg→lb, mmHg→kPa), matching the dashboard. Glucose is
    // already server-converted on the series payload (passed through).
    @Environment(\.unitPreferences) private var units
    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // DASHBOARD-CHARTS-BUG-FIX (2026-05-16): the latest series
                // point is the hero's ground truth — render it whenever
                // present, regardless of `dataState`. Previously the
                // hero stayed on `ProgressView` whenever the SECOND
                // (recent-page) fetch failed or the dataState had not
                // landed yet, even though the series had already returned
                // a valid `latestPoint`. Operator saw a spinning hero with
                // no value despite series being loaded.
                //
                // PA4 #2/#3 still holds: hero/chart/stats agree because
                // every surface short-circuits on `series` presence first
                // before consulting `dataState` for empty-state copy.
                if let latest = store.latestPoint {
                    readyContent(latest: latest)
                } else if case let .empty(reason) = store.dataState {
                    emptyContent(reason: reason)
                } else {
                    // No latest point AND dataState pending — spinner.
                    ProgressView().padding(.vertical, HLSpace.md)
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
        HStack(alignment: .top, spacing: HLSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                Text(formattedValue(latest)) // W-IMPL-MOTION-POLISH destination ↓
                    .font(.hlMetric(.largeTitle))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                    // v0.8.0 W6 — 0.6 → 0.75: keep the HeroStrip value legible at
                    // large Dynamic Type instead of crushing it below its caption.
                    .minimumScaleFactor(0.75)
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
            }
            Spacer()
            if let delta = store.deltaVsPriorWindow {
                // A360-5 — the prior-window delta + its label both convert for
                // the re-unitable weight/BP families (purely multiplicative;
                // glucose series deltas are already in the user's unit), so the
                // chip never mixes a converted label with a canonical magnitude.
                HeroDeltaChip(delta: store.convertDelta(delta, units: units), unit: store.displayUnit(units: units))
            }
        }
        Text(latest.at, format: .dateTime.weekday(.wide).day().month().hour().minute())
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
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

    @ViewBuilder
    private func emptyContent(reason: EmptyReason) -> some View {
        switch reason {
        case .noData:
            Text("No data yet")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        case let .outsideRange(latestAt):
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("No measurements in the selected range")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                Text(latestAt, format: .relative(presentation: .named))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        case .sourceFiltered:
            Text("No measurements for the selected source")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
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
    @Environment(\.unitPreferences) private var units

    let kind: MetricKind
    let store: ChartDetailStore
    @Binding var selectedDate: Date?
    /// v0.12 W8-9 — native horizontal pan position. Bound to
    /// `chartScrollPosition(x:)` so the scroll offset survives re-renders. Swift
    /// Charts clamps the seed into the data domain on first paint and updates it
    /// as the user pans; `.now` is a harmless initial leading anchor.
    @State private var scrollPositionX: Date = .now
    /// v0.14 DATA — belt-and-suspenders loading timeout. If the chart sits in the
    /// spinner `else` arm (no series + `dataState` still pending) past this
    /// budget, degrade to the "Noch keine Daten" card so no card can spin
    /// forever — mirrors `DashboardEmptyTilePolicy.loadingTimeoutSeconds`. The
    /// store's `defer`-settle already guarantees `dataState` resolves, so this
    /// only ever fires for a wedged-store edge (cancelled task that never
    /// re-drove `.task(id:)`).
    @State private var loadingTimedOut = false
    private static let loadingTimeoutSeconds: UInt64 = 3
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

    var body: some View {
        // DASHBOARD-CHARTS-BUG-FIX (2026-05-16): `series` is the chart's
        // ground truth — render whenever it carries >= 2 points, regardless
        // of `dataState`. Order of precedence: >= 2 points → chart,
        // 1 point → "Need more data", `.empty` → "Noch keine Daten",
        // otherwise spinner. PA4 #3/#5: hero/chart/stats agreement still
        // holds because every surface short-circuits on `series` presence
        // before falling back to `dataState`.
        if store.chartPoints.count >= 2 {
            HLCard {
                chartView
                    .frame(height: HLChartStyle.heightDetail + 80)
                    // #55 — dim the populated chart while a reload is in flight
                    // so a range change reads as "updating", never frozen.
                    .opacity(store.isLoading ? 0.45 : 1)
                    .overlay {
                        if store.isLoading {
                            reloadAffordance
                        }
                    }
                    .hlAnimation(.easeInOut(duration: 0.2), value: store.isLoading)
                    // The dimmed chart is decorative during a reload — let
                    // VoiceOver announce the loading state instead of reading
                    // out the stale (about-to-change) data series.
                    .accessibilityValue(store.isLoading ? Text(String(localized: "Loading")) : Text(""))
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapChart() }
            // W3b C1 — zoom-morph source for the fullscreen cover (iOS 18+).
            .matchedTransitionSource(id: zoomSourceID, in: zoomNamespace)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(String(localized: "Double-tap to open the chart full screen")))
        } else if store.chartPoints.count == 1 {
            // Series landed but only one point — Apple-Health "Need more
            // data" copy. Independent of dataState (which may still be
            // .loading at this moment).
            InsufficientDataCard(kind: kind, hasOnePoint: true)
        } else if case .empty = store.dataState {
            // No series AND dataState confirmed empty — full "Noch keine
            // Daten" card.
            InsufficientDataCard(kind: kind, hasOnePoint: false)
        } else if loadingTimedOut {
            // v0.14 DATA — spinner outlived its budget; degrade to the empty
            // card instead of an infinite ProgressView.
            InsufficientDataCard(kind: kind, hasOnePoint: false)
        } else {
            // No series yet AND dataState pending — loading spinner with a
            // hard timeout fallback so it can never spin forever.
            HLCard {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: HLChartStyle.heightDetail + 80)
            }
            .task(id: store.isLoading) {
                guard !store.isLoading else { return }
                try? await Task.sleep(nanoseconds: Self.loadingTimeoutSeconds * 1_000_000_000)
                if !Task.isCancelled { loadingTimedOut = true }
            }
        }
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
        let points = store.chartPoints
        if points.count >= 2 {
            Chart {
                MetricChartContent.marks(
                    for: kind,
                    points: points,
                    emphasisTint: emphasisTint
                )

                if let selectedDate, let selectedPoint = nearestPoint(to: selectedDate, in: points) {
                    // Apple-Health-style scrubber: dashed vertical RuleMark
                    // anchored at the nearest point's x, with the floating
                    // callout pinned to top. The dashed pattern reads as
                    // "interactive overlay" rather than a data series.
                    // T2-3: tint routes through `HLChartTints.seriesMid`
                    // (single accent at 70% opacity) — visually identical
                    // to the previous `.purple.opacity(0.55)` but sourced
                    // from the locked Theme-2.0 chart palette so any
                    // future accent swap propagates here automatically.
                    RuleMark(x: .value("Auswahl", selectedPoint.at))
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
                        }
                    // Highlighted point marker — emphasizes the value the
                    // callout describes. Larger than the per-metric symbols.
                    PointMark(
                        x: .value("Auswahl", selectedPoint.at),
                        y: .value("Wert", selectedPoint.value)
                    )
                    .foregroundStyle(HLChartTints.series)
                    .symbolSize(120)
                    if let secondary = selectedPoint.secondary {
                        // BP — emphasize both lines under the cursor. The
                        // diastolic dot matches the BP secondary-line tint
                        // (single accent at 70% opacity).
                        PointMark(
                            x: .value("Auswahl", selectedPoint.at),
                            y: .value("Diastolisch", secondary)
                        )
                        .foregroundStyle(HLChartTints.seriesMid)
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
                domain: MetricChartMath.logDomain(for: points),
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
                // unchanged from `kind.unit` for un-stamped kinds.
                Text(store.displayUnit)
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
            // Honour reduce-motion via .hlAnimation (audit M16). The Chart
            // morphs new line shapes between range changes — `.snappy` feels
            // right for ~350ms of y-rescale + line draw.
            .hlAnimation(.snappy(duration: 0.35), value: store.range)
            .accessibilityChartDescriptor(
                ChartDescriptor(
                    descriptor: ChartsAccessibility.makeDescriptor(
                        for: store.displaySeries
                            ?? MeasurementSeries(kind: kind, points: points, stats: MetricChartMath.statsFor(points)),
                        kind: kind
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

// MARK: - Stats summary row (Apple-Health-style)

/// Four-card statistic summary — Min, Ø (mean), Max, Median.
///
/// Median is the additive Charlie-v0.4.0 stat (the prior row showed σ, which
/// is information-dense but less actionable for end users; Apple Health uses
/// Min/Avg/Max + an "Auf einen Blick" median-equivalent). Median is computed
/// on-device from the rendered series via `ChartDetailStore.median`. σ stays
/// available in `SeriesStats` for future deep-dives but isn't surfaced here.
struct StatsRow: View {
    let stats: SeriesStats?
    let median: Double?
    let unit: String
    /// A360-5 C-1 — the metric kind drives unit conversion of the stats. Default
    /// `nil` keeps existing call-sites compiling and renders the raw value (the
    /// pre-fix behaviour) until they pass a kind; the in-app call-sites all pass
    /// it so weight/BP convert. Glucose stats are already server-converted.
    var kind: MetricKind?
    var units: UnitPreferences = .standard

    var body: some View {
        if let stats {
            HStack(spacing: HLSpace.sm) {
                StatBox(label: String(localized: "Min"), value: format(stats.min), unit: unit)
                StatBox(label: String(localized: "chart.stat.mean"), value: format(stats.mean), unit: unit)
                StatBox(label: String(localized: "Max"), value: format(stats.max), unit: unit)
                if let median {
                    StatBox(label: String(localized: "chart.stat.median"), value: format(median), unit: unit)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Converts a stat into the user's unit. Series stats are canonical for
    /// weight/BP (convert) and already server-converted for glucose (pass
    /// through), mirroring the hero/point formatter. Falls back to the prior
    /// raw 0…1-dp rendering when no `kind` is supplied.
    ///
    /// **BH-final-diff H6/M5** — the precision per family must match the
    /// hero/callout EXACTLY so the same chart screen never disagrees with
    /// itself. Weight uses 1-dp (the dashboard/hero canonical `fractionLength(1)`
    /// → `80.0`); BP is integer-grained for mmHg and 1-dp for kPa (a single
    /// leg's value, since the stats row renders systolic/diastolic separately).
    private func format(_ v: Double) -> String {
        guard let kind else {
            return v.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        switch kind.unitFamily {
        case .weight:
            // Match the hero/list canonical 1-dp (NOT `0...1`, which dropped the
            // trailing `.0` for whole values and disagreed with the hero).
            return units.convertWeight(v).formatted(.number.precision(.fractionLength(1)))
        case .bloodPressure:
            // Match `MetricValueFormatter.formatBloodPressure` per-leg precision:
            // mmHg integer-grained, kPa 1-dp.
            let converted = units.convertBloodPressure(v)
            return units.bloodPressure == .mmHg
                ? converted.safeServerIntString()
                : converted.formatted(.number.precision(.fractionLength(1)))
        case .glucose, .none:
            // Glucose already server-converted; `.none` keeps canonical value.
            return v.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
    }
}

/// **v0.6.1.6 — Y6 — AP-005.** Min / Ø / Max / Median pills routed onto
/// the Tonal-Mono `HLText.*` scale per handbook §2.8 — value `.primary`,
/// label `.secondary`, unit `.tertiary`. Operator quote: *"bei Min, Max,
/// Median und oben wo ich den Zeitraum auswählen kann, das sind so
/// dunkelblaue Elemente … Das sollte alles in diesem Schwarz sein."* The
/// prior `HLText.primary` Dracula-tinted asset read as a faint
/// purple-blue on the headline-weight value glyph. Pill background locks
/// to `HLSurface.tertiary` (canonical recessed-well surface).
struct StatBox: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: HLSpace.xxs) {
            // A2 (v0153 a11y MEDIUM) — up to 4 boxes share a 393 pt row (~90 pt
            // each), doubled on the BP systolic/diastolic strip. At AX4/AX5 the
            // caption/value/unit would wrap or clip silently; clamp to one line
            // and scale down instead of truncating.
            Text(label).font(.hlCaption).foregroundStyle(HLText.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.hlMetric(.headline)).foregroundStyle(HLText.primary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.hlCaption).foregroundStyle(HLText.tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.sm)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label) \(value) \(unit)"))
    }
}
