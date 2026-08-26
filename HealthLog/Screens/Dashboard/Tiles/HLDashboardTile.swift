import SwiftUI

/// Dashboard metric tile — the canonical layout for every metric rendered
/// on the Dashboard grid. Uses `MetricKindDescriptor` (the v0.4.0 registry)
/// as the source of truth for icon, tint, title, unit, format, and trend
/// polarity, but renders with the lighter v0.3.0 visual aesthetic the user
/// preferred over the heavier v0.4.0 first-cut.
///
/// **Layout** (1×1 cell inside a 2-column `LazyVGrid`):
///
/// ```
/// ┌────────────────────────────┐
/// │ ◐ Gewicht           ↓     │ ← icon + title + trend chip
/// │ 72,4 kg                    │ ← primary value (rounded-bold) + unit
/// │ ╱╲╱╲╱                      │ ← 7-day sparkline (area, 36pt tall)
/// └────────────────────────────┘
/// ```
///
/// **What v0.4.0-revert removed (user feedback 2026-05-15):**
/// - Big "—" + empty-state-copy block — felt heavy for tiles that simply
///   have no data yet; the `boneMass` tile took as much room as one with
///   real numbers. Empty value collapses to a single em-dash inline.
/// - Bottom-right `ProvenanceChip` ("Health App") inside the sparkline
///   row — redundant noise; provenance now surfaces only in the
///   drill-down detail screen.
///
/// **What stays from v0.4.0:**
/// - `MetricKindDescriptor` registry resolution (single source of truth)
/// - Polarity-aware `TrendChip` (now monochrome by default, red only on
///   adverse trend — see TrendChip type-doc for C-5 flattening rationale)
/// - Combined accessibility label + drill-down hint
///
/// **Accessibility:** `accessibilityElement(children: .combine)` with a
/// composed VoiceOver label — "Schritte heute: 8.234. Trend steigend.
/// Doppeltippen für Details." Respects Dynamic Type up to AX5 via
/// `@ScaledMetric`.
public struct HLDashboardTile: View {
    public enum Size {
        case compact // 1×1 grid cell
        case wide // 1×2 (spans both columns)
    }

    // AUD-2 H4 — `metric` / `dataState` / `liveTodayStepsOverride` are
    // `internal` (not `private`) so the context-line memo extension in
    // `HLDashboardTile+ContextLine.swift` can read them. They remain
    // immutable `let`s set only at init.
    let metric: DashboardMetric
    private let descriptor: MetricKindDescriptor
    private let size: Size
    /// Unified data-state for this tile's metric, sourced from
    /// `DashboardStore.metricStates[metric.kind]`. The PA4 fix: the tile's
    /// empty-vs-ready predicate routes through this state — populated by
    /// the SAME `/api/measurements` call the chart-detail screen consumes
    /// — so the tile can never claim "no data" when the detail can show it.
    ///
    /// Defaults to `.unknown` for callers that haven't migrated yet
    /// (previews + tests). In that fall-through mode the tile resolves
    /// emptiness from `metric.latestValue` as before — same behaviour as
    /// pre-PB5 builds.
    let dataState: MetricDataState
    /// W-IMPL-MOTION-POLISH (v0.5.5.1) — matched-geometry namespace owned
    /// by `DashboardScreen`. When non-nil, the value text becomes the
    /// source of a shared-element transition that lifts into the
    /// `ChartDetailScreen.HeroStrip` number on tap. `nil` under
    /// reduce-motion + on surfaces that don't host a namespace (previews,
    /// snapshot tests, Charts list path).
    private let matchedNamespace: Namespace.ID?
    /// v0.6.2.x bug-c10-ios-direct — HK-direct today step total, supplied
    /// by `DashboardScreen` via `LiveHealthKitTodayStore`. Honored only
    /// when `metric.kind == .steps`. `nil` falls through to the existing
    /// summary / dataState path so the rest of the tile cohort is
    /// unaffected.
    let liveTodayStepsOverride: Double?

    /// Build 7 / item 7.1 — the web dashboard tile (`trend-card.tsx`) ships a
    /// 7-/30-day average sub-row on every card. `avg7`/`avg30` are the
    /// server-canonical averages projected from `ComprehensiveDigest.summaries`
    /// by `DashboardTileTargetResolver`; the tile formats + unit-converts them
    /// through the SAME `formatScalar` path as its headline value so the sub-row
    /// and the value can't drift on units/rounding. Both `nil` (previews, tests,
    /// the sleep composite path, cold-launch before the digest lands) → the
    /// sub-row is omitted, identical to the pre-7.1 tile.
    let avg7: Double?
    let avg30: Double?
    /// Build 7 / item 7.1 — optional target band ("Zielband"), the BP-style
    /// in-range rail carried to every ranged tile (analog to the web tile's
    /// range-coloured averages + the Insights target tiles). `nil` → no band,
    /// exactly as BP omits it when no target is configured.
    let targetBand: RangeBand?

    @ScaledMetric(relativeTo: .title2) private var primaryValueSize: CGFloat = 28

    /// AUD-2 H4 — memoized context line (see `HLDashboardTile+ContextLine`).
    /// The `MetricDisplay` date-math projection runs only when this tile's
    /// inputs change (`.task(id:)`), not on every dashboard body pass.
    @State private var cachedContextLine: String?

    /// v0.11 N1 — user display-unit prefs, injected at the dashboard root.
    /// Drives weight/BP/glucose conversion + the unit suffix shown below the
    /// value. Defaults to `.standard` (canonical SI) for previews/tests.
    /// AUD-2 H4 — `internal` so the context-line memo extension can read it.
    @Environment(\.unitPreferences) var unitPreferences

    /// `provenance` is accepted for source-compat with existing call sites
    /// but no longer rendered — see the type-level doc for the v0.4.0-revert
    /// rationale.
    public init(
        metric: DashboardMetric,
        provenance _: MeasurementSource? = nil,
        size: Size = .compact,
        dataState: MetricDataState = .unknown,
        matchedNamespace: Namespace.ID? = nil,
        liveTodayStepsOverride: Double? = nil,
        avg7: Double? = nil,
        avg30: Double? = nil,
        targetBand: RangeBand? = nil
    ) {
        self.metric = metric
        descriptor = metric.kind.descriptor
        self.size = size
        self.dataState = dataState
        self.matchedNamespace = matchedNamespace
        self.liveTodayStepsOverride = liveTodayStepsOverride
        self.avg7 = avg7
        self.avg30 = avg30
        self.targetBand = targetBand
    }

    public var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                headerRow
                valueRow
                // v0.14.8 AUDIT-HOME M5 — the context line ("Last measurement
                // X days ago" / "No data yet" / source-filtered) was VoiceOver-
                // only on the DEFAULT layout: hero + list rendered
                // `MetricDisplay.secondaryLine`, the cards tile routed it only
                // into the a11y label — the sighted user saw a bare "—" with
                // no explanation. Calm tertiary caption, hidden when nil.
                if let cachedContextLine {
                    Text(cachedContextLine)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tile.\(metric.kind.rawValue).context")
                }
                sparklineRow
                // Build 7 / item 7.1 — 7-/30-day averages + target band, the
                // web dashboard tile's secondary stats. Gated on a non-empty
                // tile so a "no data yet" card stays calm (no averages against
                // an em-dash headline). Order mirrors `HLMetricTile` (Insights):
                // stats caption, then the BP-style in-range rail.
                if !isEmptyForDisplay, hasAverages {
                    averagesRow
                }
                if !isEmptyForDisplay, let targetBand {
                    RangeBandRow(band: targetBand)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibilityLabel)
        .accessibilityHint(descriptor.supportsDrillDown
            ? Text(String(localized: "Double-tap to open detail view"))
            : Text(""))
        // V0.5.4.3 HP-2 — accessibility identifier for the walkthrough
        // XCUITest contract. The suffix encodes the sparkline-state directly
        // in the identifier (the children-combine on this element flattens
        // any nested identifier so we cannot use a separate per-row element)
        // so the assertion can grep e.g. `tile.bloodPressure.withChart` to
        // assert the BP tile is painting a chart, not just the value row.
        .accessibilityIdentifier(
            "tile.\(metric.kind.rawValue).\(sparklineValues.count >= 2 ? "withChart" : "noChart")"
        )
        // AUD-2 H4 — recompute the `MetricDisplay`-derived context line only
        // when this tile's inputs change, not on every body pass. The memo
        // helpers (`contextLineKey`, `computeContextLine`, `ContextLineKey`)
        // live in `HLDashboardTile+ContextLine.swift`.
        .task(id: contextLineKey) { cachedContextLine = computeContextLine() }
    }

    // MARK: - Header

    private var headerRow: some View {
        // C-1 (R1 Strategy C, Layer 2 "Content"): icon foreground is monochrome
        // at rest — `descriptor.tint` no longer paints tile chrome. W6b: glyph +
        // title now route through the shared `HLMetricTileChrome` primitives (the
        // single tile-fragment code path); the polarity-aware `TrendChip` is the
        // trailing accessory (it itself renders via `HLTileTrendGlyph`).
        HLTileHeaderRow(icon: descriptor.sfSymbol, title: Text(descriptor.title)) {
            TrendChip(
                trend: metric.dashboardTrend,
                polarity: descriptor.trendPolarity,
                mode: metric.dashboardTrendMode
            )
        }
    }

    // MARK: - Value + unit

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(formattedValueText)
                .font(.hlMetric(primaryValueSize))
                .foregroundStyle(isEmptyForDisplay ? HLText.tertiary : HLText.primary)
                .monospacedDigit()
                // v0.8.7 W-TILE-DYNAMICS — digits roll on value update (mirrors
                // RecordCard). #57: routed through `.hlAnimation` so Reduce-Motion
                // disables the roll (env-gated, not just the native cross-fade).
                .contentTransition(.numericText())
                .hlAnimation(.snappy(duration: 0.25), value: formattedValueText)
                .lineLimit(1)
                // v0.8.0 W6 — 0.6 → 0.75: a 60% clamp at AX5 shrank the
                // headline value below the caption beside it, inverting
                // hierarchy. 0.75 sits at Apple's practical legibility floor.
                .minimumScaleFactor(0.75)
                // V0.5.4.3-HP3: XCUI hook so the walkthrough can read the
                // rendered value-string per kind (e.g. `tile.steps.value`)
                // and assert against day-cumulative output. The text node
                // sits inside `accessibilityElement(children: .combine)`,
                // but the inner element keeps its own identifier so the
                // XCUI tree resolves the per-row text leaf cleanly.
                .accessibilityIdentifier("tile.\(metric.kind.rawValue).value")
                // W-IMPL-MOTION-POLISH (v0.5.5.1) — shared-element source.
                // The destination `ChartDetailScreen.HeroStrip` applies the
                // same id inside the same namespace and the tile number
                // flies into the chart-detail hero on tap. `matchedNamespace`
                // is `nil` under reduce-motion → modifier resolves to the
                // identity branch + no implicit frame animation runs.
                .matchedTileGeometry(
                    id: DashboardMatchedGeometryID.value(for: metric.kind),
                    in: matchedNamespace
                )
            Text(metric.unitSuffix(units: unitPreferences))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Context line (v0.14.8 AUDIT-HOME M5)

    // Visible secondary line resolved through the SAME `MetricDisplay`
    // projection hero + list already render — the three layouts can't
    // drift on the copy. `nil` for fresh `.ready` values (clean tile) and
    // during `.unknown`/`.loading` first-paint.

    // MARK: - State-aware predicate (PA4 unified data source)

    /// `true` when the tile should render the em-dash placeholder. Prefers
    /// the unified `dataState` when it has resolved (`.ready` ⇒ false,
    /// `.empty` ⇒ true); falls back to the legacy `metric.latestValue`
    /// predicate while state is `.unknown / .loading` so cold-launch
    /// first-paint still gets a value from the summary endpoint.
    ///
    /// PA4 #8 (BP composite): when `.ready` but `metric.secondaryValue`
    /// is missing for a `.bloodPressureCompound` formatter, we treat the
    /// tile as half-loaded — em-dash rather than misleading single value.
    private var isEmptyForDisplay: Bool {
        switch dataState {
        case .ready:
            // Composite metrics need both components — half-loaded BP would
            // otherwise render "124" with no diastolic, contradicting the
            // accessibility label ("noch keine Daten") on the same surface.
            if descriptor.formatStyle == .bloodPressureCompound, metric.secondaryValue == nil {
                return true
            }
            return false
        case .empty:
            return true
        case .unknown, .loading:
            // No state resolved yet — defer to the summary-endpoint snapshot
            // for first-paint. Composite-incomplete also short-circuits to
            // empty for the same reason as above.
            if descriptor.formatStyle == .bloodPressureCompound, metric.secondaryValue == nil {
                return true
            }
            // v0.6.2.x bug-c10-ios-direct — Steps tile considers the live
            // HK value enough to count as "ready" even before the dataState
            // fan-out has landed.
            if metric.kind == .steps, liveTodayStepsOverride != nil {
                return false
            }
            return metric.latestValue == nil
        }
    }

    /// Display string for the value-row. Prefers the unified `dataState`
    /// when ready (newest measurement from the same endpoint the detail
    /// uses); otherwise falls through to the summary-endpoint snapshot.
    ///
    /// **V0.5.4-BF-3 cumulative path.** Kinds where
    /// `MetricKind.isCumulative == true` (Steps, future sum-per-day
    /// metrics) display today's day-cumulative sum, not the latest single
    /// sample. The summation runs over the `.ready` arm's `samples` slice;
    /// when no same-day sample exists we fall back to `latest.primaryValue`
    /// so the tile never silently blanks before today's HK upload has
    /// landed.
    private var formattedValueText: String {
        if case let .ready(latest, samples) = dataState {
            // BP composite needs the diastolic peer from the summary —
            // `MeasurementValue.bloodPressure` carries both, scalar does
            // not. Composite-incomplete falls through to the dash via
            // `isEmptyForDisplay`.
            if descriptor.formatStyle == .bloodPressureCompound {
                if case let .bloodPressure(s, d) = latest.value {
                    let sysValue = unitPreferences.convertBloodPressure(s)
                    let diaValue = unitPreferences.convertBloodPressure(d)
                    if unitPreferences.bloodPressure == .mmHg {
                        // W-CRASHGUARD — em-dash if either operand is non-finite / OOR.
                        return Double.safeServerBPString(systolic: sysValue, diastolic: diaValue)
                    }
                    return "\(sysValue.formatted(.number.precision(.fractionLength(1))))/\(diaValue.formatted(.number.precision(.fractionLength(1))))"
                }
                // Composite metric but the latest sample is not paired —
                // mirror `isEmptyForDisplay` and render the placeholder.
                return "—"
            }
            if metric.kind.isCumulative {
                // v0.6.2.x bug-c10-ios-direct — Steps prefers the HK-direct
                // live value over the server-derived day-sum. The server
                // path is frozen for the rest of today (insert-only batch
                // route) but HK is monotonic on the device, so the live
                // read is the only honest "what walked today" number.
                let liveValue = (metric.kind == .steps) ? liveTodayStepsOverride : nil
                let todaySum = MetricDisplay.cumulativeTodaySum(samples: samples)
                let value = liveValue ?? todaySum ?? latest.primaryValue
                return formatScalar(value)
            }
            return formatScalar(latest.primaryValue)
        }
        // v0.6.2.x bug-c10-ios-direct — even before the dataState fan-out
        // resolves, render the live HK-direct value for Steps so the
        // first-paint cold-launch number is fresh instead of stale.
        if metric.kind == .steps, let liveValue = liveTodayStepsOverride {
            return formatScalar(liveValue)
        }
        return metric.formattedPrimary(units: unitPreferences)
    }

    /// Mirrors `MetricKindDescriptor.formattedPrimary` for the scalar
    /// formatters. Kept local to avoid recomputing through `DashboardMetric`
    /// when the value lands via `MetricDataState` instead of the summary
    /// endpoint.
    ///
    /// v0.11 N1 — the re-unitable families (weight / glucose) convert at
    /// display time via `unitPreferences`. Blood-pressure is handled in
    /// `formattedValueText` (composite path) so it never reaches here.
    ///
    /// v0.16 Build 7 / item 7.1 — `internal` (not `private`) so the
    /// `HLDashboardTile+SecondaryStats` extension formats the 7-/30-day
    /// averages through the identical unit-conversion path.
    func formatScalar(_ latest: Double) -> String {
        // W-CRASHGUARD — `latest` is an unsanitized server / HK-direct scalar;
        // every `Int(...)` below traps on non-finite AND out-of-`Int.range`.
        // Reject non-finite at the gate; route each conversion through
        // `Int(safeServer:)` → em-dash on an unrepresentable value.
        guard latest.isFinite else { return "—" }
        switch metric.kind.unitFamily {
        case .weight:
            return unitPreferences.convertWeight(latest).formatted(.number.precision(.fractionLength(1)))
        case .glucose:
            let v = unitPreferences.convertGlucose(latest)
            return unitPreferences.glucose == .mgdL
                ? v.safeServerIntString()
                : v.formatted(.number.precision(.fractionLength(1)))
        case .bloodPressure, .none:
            break
        }
        switch descriptor.formatStyle {
        case .integer:
            return latest.safeServerIntString()
        case .decimal1:
            return latest.formatted(.number.precision(.fractionLength(1)))
        case .decimal2:
            return latest.formatted(.number.precision(.fractionLength(0 ... 2)))
        case .bloodPressureCompound:
            // Unreachable — `formattedValueText` short-circuits earlier for
            // composite metrics. Defensive fallback to single integer.
            return latest.safeServerIntString()
        case .durationHM:
            return latest.safeServerSleepDurationHM
        case .groupedInteger:
            return latest.safeServerGroupedIntString
        case .signedDecimal1:
            // W-B189 (#23) — signed deviation (body-temperature deviation).
            return MetricKindDescriptor.formatSignedDecimal1(latest)
        }
    }

    // MARK: - Sparkline

    private var sparklineRow: some View {
        // C-1 + C-6 + Theme-2.0 (T2-2): sparkline at-rest is monochrome
        // (`HLText.tertiary`) and pure `.line` (HLSparkline default per R2
        // §Primitive #3). The per-metric Dracula `descriptor.tint` is gone
        // entirely (T2-2 collapsed it to surfaceSecondary); chart-detail
        // emphasis is the only surviving per-series accent path.
        //
        // **V053-D2 universal sparkline.** When the summary's
        // `metric.sparkline` is empty (server omitted, or the layout-
        // synthesized placeholder), fall back to the unified `dataState`'s
        // samples. The store's `refreshMetricStates` hydrates the summary
        // sparkline async; this guard renders a chart immediately as soon
        // as ANY data path resolves the kind to `.ready`. No tile with
        // data should ever paint a blank sparkline.
        //
        // W6b — the single chart-row code path (36pt). Task #36 — `metric.kind`
        // routes it through the SAME `MetricChartContent` engine + `inkGraphite`
        // ink as the Insights page (per-metric vocabulary, not a grey line).
        HLTileSparkline(values: sparklineValues, kind: metric.kind)
    }

    /// Resolves the sparkline source: prefer the summary's pre-aggregated
    /// `metric.sparkline` whenever it carries enough points to render
    /// (`HLSparkline` requires ≥2 to draw a line — anything less collapses to
    /// the `emptyHairline` branch which reads visually as "no chart"). When
    /// the summary sparkline is too thin (server's `measurement_rollups` table
    /// shipped 0 or 1 daily buckets for low-frequency manual kinds), fall
    /// through to the unified-data-state samples — the same input
    /// `ChartDetailScreen` paints its chart from.
    ///
    /// **REG-11 root cause (v0.5.6, 5th BP+Puls+BodyFat attempt).** Pre-fix
    /// the gate was `if !metric.sparkline.isEmpty` — a server payload of
    /// `sparkline: [124]` (one daily bucket — the realistic shape for BP /
    /// Pulse / BodyFat manual entry accounts) passed the gate and was handed
    /// to `HLSparkline`, which collapsed it to the hairline placeholder. The
    /// tile then read as chartless even though `dataState` had a full
    /// `.ready(_, samples)` payload from the wide-page or series fallback.
    /// `ChartDetailScreen` loads from `/api/measurements/series` directly,
    /// which always returns the full per-sample series, so the detail kept
    /// rendering a chart correctly — producing the operator-reported "Tile
    /// leer, Detail voll" regression across v0.5.1, v0.5.5, v0.5.5.2, and
    /// v0.5.5.3.
    ///
    /// **V0.5.4.3 HP-2 — kind-aware projection.** The fallback path routes
    /// through `MetricSeriesProjection.project(_:kind:)` instead of mapping
    /// `\.value.primaryComponent` inline. For BP this drops unpaired-DIA
    /// artifacts (`MeasurementValue.bloodPressure(systolic: 0, _)`) whose
    /// zero systolic crushed the chart's y-domain to a 4 pt sliver at the
    /// very top of the tile. See `MetricSeriesProjection` type-doc for the
    /// forensic trail.
    var sparklineValues: [Double] {
        Self.resolveSparklineValues(
            summarySparkline: metric.sparkline,
            dataState: dataState,
            kind: metric.kind
        )
    }

    /// Pure resolution helper — exposed `nonisolated static` so unit tests
    /// can pin the precedence contract without spinning up a SwiftUI render
    /// pass.
    ///
    /// **REG-11 (v0.5.5.5, 5th attempt) — fall-through precedence.** Four
    /// prior fixes survived their unit tests but kept landing the same
    /// operator-reported "BP / Puls / Körperfett tile zeigt keinen Chart"
    /// regression because the store-hydration path was load-bearing — when
    /// it failed to enrich `summary.metrics[kind].sparkline` from `[N]` to
    /// `[N, …, M]` for any reason (timing race, missing summary entry,
    /// fan-out hadn't landed by the time the tile read the metric), the
    /// resolver was stuck handing `HLSparkline` a single-point series which
    /// collapses to the empty-hairline branch. The new contract pulls the
    /// resolution into the tile itself so the chart paints as soon as
    /// **either** source carries enough points — without depending on the
    /// store-side hydration happening first:
    ///
    /// 1. Project the unified `dataState` samples through the kind-aware
    ///    `MetricSeriesProjection` (drops BP unpaired-DIA artifacts, etc.).
    /// 2. If both `summarySparkline` and `projected` carry ≥2 points,
    ///    pick the one with more detail — server may have day-bucketed,
    ///    raw samples may carry more density. Either way more is better
    ///    signal at sparkline scale.
    /// 3. Otherwise prefer whichever one renders (`≥ 2` — the `HLSparkline`
    ///    chart-vs-hairline threshold).
    /// 4. If neither renders, return the summary sparkline as-is (hairline
    ///    is honest signal that the tile knows the latest value but has no
    ///    trend context yet).
    ///
    /// This eliminates the four-recurring "Tile leer, Detail voll" symptom
    /// because the tile no longer needs the store-side hydration to have
    /// committed before it can paint a chart — having the same samples
    /// `ChartDetailScreen` reads is sufficient.
    nonisolated static func resolveSparklineValues(
        summarySparkline: [Double],
        dataState: MetricDataState,
        kind: MetricKind
    ) -> [Double] {
        let projected: [Double] = if case let .ready(_, samples) = dataState {
            MetricSeriesProjection.project(samples, kind: kind)
        } else {
            []
        }
        let serverRenderable = summarySparkline.count >= 2
        let projectedRenderable = projected.count >= 2

        let result: [Double] = switch (serverRenderable, projectedRenderable) {
        case (true, true):
            // Both render — pick the path with more detail.
            projected.count > summarySparkline.count ? projected : summarySparkline
        case (true, false):
            summarySparkline
        case (false, true):
            projected
        case (false, false):
            // Neither renders — keep the summary's signal (HLSparkline
            // hairline branch). Empty array would render the same way; we
            // return the summary array so the value count in the
            // accessibility identifier reflects the server payload shape.
            summarySparkline
        }

        // **REG-11 forensic trail.** On-device Console logs whenever the
        // tile resolves to a non-renderable series — the operator can grep
        // `category == "ui"` while reproducing to see WHICH path failed.
        // Production-cheap: only fires when count < 2, which is exactly
        // the bug state.
        if result.count < 2 {
            let kindKey = kind.rawValue
            let summaryCount = summarySparkline.count
            let projectedCount = projected.count
            let readyFlag = dataState.hasValue
            // MetricKind key + counts + boolean — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.ui.debug(
                "REG-11 tile.\(kindKey, privacy: .public) sparkline thin (summary=\(summaryCount, privacy: .public) projected=\(projectedCount, privacy: .public) ready=\(readyFlag, privacy: .public))"
            )
        }
        return result
    }

    // MARK: - Accessibility

    private var combinedAccessibilityLabel: Text {
        let title = String(localized: descriptor.title)
        if isEmptyForDisplay {
            // Distinguish "no data ever" from "outside the queried window"
            // so VoiceOver users know whether to log a first reading or
            // simply broaden the range — same intent the visible tile
            // would convey if we surfaced a "letzte vor X Tagen" sublabel.
            if case let .empty(.outsideRange(latestAt)) = dataState {
                // F7 (PB5 review): clock-skewed manual entry / HK background-
                // delivery race can yield a future `latestAt` → "vor -2 Tagen".
                // Clamp at 0 so the spoken label always reads sensibly.
                let raw = Calendar.current.dateComponents([.day], from: latestAt, to: .now).day ?? 0
                let days = max(0, raw)
                return Text(String(localized: "\(title): Last measurement \(days) days ago"))
            }
            return Text(String(localized: "\(title): No data yet"))
        }
        let value = "\(formattedValueText) \(metric.unitSuffix(units: unitPreferences))"
        let trendDesc = switch metric.dashboardTrend {
        case .up: String(localized: "Trend rising")
        case .down: String(localized: "Trend falling")
        case .flat: String(localized: "Trend stable")
        case .unknown: String(localized: "Trend unknown")
        }
        // v0.14.8 AUDIT-HOME M5 — the visible recency hint ("Last
        // measurement X days ago" on stale `.ready` values) is spoken too.
        // AUD-2 H4 — reads the same memoized `cachedContextLine` the visible
        // caption renders, so VoiceOver and the sighted line never diverge.
        // Build 7 / item 7.1 — fold the averages + target band into the spoken
        // label so VoiceOver hears the same secondary stats the sighted user
        // now reads on the tile.
        let stats = statsSpokenClause
        if let cachedContextLine {
            return Text("\(title): \(value). \(trendDesc). \(cachedContextLine).\(stats)")
        }
        return Text("\(title): \(value). \(trendDesc).\(stats)")
    }
}

// MARK: - Trend chip (polarity-aware, monochrome)

//
// Moved to `HLDashboardTile+TrendChip.swift` (v0.16 Build 7 / item 7.1 split)
// so the 7-/30-day-average additions kept this file under the `file_length`
// budget.

// MARK: - Previews

//
// Moved to `HLDashboardTile+Previews.swift` (AUD-2 H4 split) so the H4
// context-line memo additions kept the file under the `file_length` budget.
