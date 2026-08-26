import Foundation
import Observation

/// Owns the state of a single chart-detail screen — range selection, source
/// filter, the loaded series for that combination, and server-fetched findings.
///
/// **Lifecycle:** one instance per opened detail screen. `ChartDetailScreen.task(id:)`
/// re-runs `load()` when `queryKey` changes, which moves whenever the user changes
/// range / source filter. Cancellation: any in-flight load is replaced by the
/// newer one (a faster picker change wins).
@MainActor
@Observable
public final class ChartDetailStore {
    // MARK: - Range

    /// Period selector for the detail chart — mirrors Apple Health's
    /// single-letter T/W/M/6M/Y vocabulary (STANDARDS §8) so the muscle memory
    /// carries over for users who switch between the two surfaces. The DE
    /// catalogue supplies "J" for the EN-source "Y" key.
    ///
    /// Raw int = window size in days, drives `MeasurementsRepository.series`
    /// directly. The "Tag" case is a 1-day window for at-a-glance current-day
    /// readings (today + cursor through the day) — useful for glucose / BP
    /// spot-readings where the user wants to see today's variation, not
    /// monthly aggregate.
    public enum Range: Int, CaseIterable, Identifiable, Sendable {
        case day = 1
        case week = 7
        case month = 30
        case sixMonths = 180
        case year = 365
        /// v0.7.0 W-STEPS Layer 4 — "alle Daten". `rawValue` doubles as the
        /// `series(days:)` window. W-SERVER-SYNC (server v1.5.5): the server
        /// raised its `days` cap to 3650, so this now carries the real
        /// all-time span to the wire — `MeasurementsRepository.serverDaysCap`
        /// equals this value, so the clamp is a no-op for `.all`.
        case all = 3650

        public var id: Int {
            rawValue
        }

        /// Short Apple-Health-style label for segmented control rendering.
        public var label: String {
            switch self {
            case .day: "T"
            case .week: "W"
            case .month: "M"
            case .sixMonths: "6M"
            case .year: String(localized: "range.label.year", defaultValue: "Y")
            case .all: String(localized: "All")
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .day: String(localized: "Day")
            case .week: String(localized: "Week")
            case .month: String(localized: "Month")
            case .sixMonths: String(localized: "6 months")
            case .year: String(localized: "Year")
            case .all: String(localized: "All data")
            }
        }
    }

    // MARK: - Inputs

    public let kind: MetricKind
    public var range: Range = .month {
        didSet { if range != oldValue { _queryKeyVersion += 1 } }
    }

    /// Optional server-source filter. `nil` = "show all sources".
    public var sourceFilter: MeasurementSource? {
        didSet { if sourceFilter != oldValue { _queryKeyVersion += 1 } }
    }

    /// Y-axis scaling mode for the detail chart. Default linear — log mode is
    /// useful for wide-dynamic-range metrics (glucose post-meal spikes,
    /// steps) where linear hides everyday detail under the peaks. The
    /// segmented toggle lives in the chart toolbar; UI-only, no re-fetch.
    public var useLogScale: Bool = false

    // MARK: - Outputs

    public internal(set) var series: MeasurementSeries?
    /// AI-Befund envelope for this metric (server `/api/insights/{metric}-status`).
    /// `nil` = no endpoint for this metric kind, the endpoint 404'd, OR
    /// the user has not granted AI-consent (in which case
    /// ``findingsConsentClosed`` is true and the UI surfaces a CTA).
    public internal(set) var findings: MetricStatusDTO?
    /// True when the most recent `load()` skipped the Befunde fetch because
    /// the AI-consent gate is closed (PB1 H1). Drives a dedicated UI state
    /// in `FindingsList` — distinguishes "user hasn't consented" from
    /// "server returned empty findings". Mirrors the consent-gate surfacing
    /// on the Insights tab.
    public internal(set) var findingsConsentClosed: Bool = false
    /// v0.7.0 W-API-RENDER — per-metric ``MetricSummary`` from the
    /// comprehensive digest (`/api/insights/comprehensive`). Carries the
    /// 7/30/90-day regression slopes + the `avg30LastYear` baseline that the
    /// HeroStrip surfaces as trend chips + a "vor 1 Jahr" delta row. `nil`
    /// until the best-effort fetch lands, or when the metric has no
    /// comprehensive summary (walking-* / BMI / sleep / steps). A failed
    /// fetch leaves it `nil` — the hero simply renders without decoration.
    public internal(set) var metricSummary: MetricSummary?
    public internal(set) var isLoading: Bool = false
    public internal(set) var error: HLError?
    /// Unified `MetricDataState` derived from the same `recent(kind:)` page
    /// the drill-down `MeasurementListScreen` consumes — so the chart's
    /// "X Einträge im Zeitraum" subtitle matches the actual list page row
    /// count (PA4 #6) and the chart-card / hero / drill-down empty
    /// predicates can never disagree (PA4 #2–#5).
    public internal(set) var dataState: MetricDataState = .unknown
    /// In-range, post-filter measurements for the current `(kind, range,
    /// sourceFilter)` triple — same set the drill-down list would render
    /// if the user tapped through right now. Held alongside `series` so
    /// the subtitle ("X Einträge") + drill-down stay in lockstep.
    public internal(set) var recentInRange: [Measurement] = []

    /// v0.14.6 N4 — the TRUE most-recent raw measurement for `(kind,
    /// sourceFilter)`, **independent of the selected range**. Captured from the
    /// full unfiltered `recent(kind:)` page (max by `recordedAt`, respecting the
    /// active source filter only), NOT the range-aggregated `displaySeries`.
    ///
    /// **Why.** The HeroStrip's "Letzte Messung" headline + timestamp must
    /// always be the real latest reading. Previously it read
    /// `displaySeries?.points.last`, which in Year/Month view is a daily/weekly
    /// BUCKET AVERAGE anchored at midnight — so switching the bottom range made
    /// "Letzte Messung" jump (Puls: Year "81,2 · Fri 00:00" vs Month "79 · Fri
    /// 14:41"). The trend slopes / delta stay on the range series; only the
    /// "Letzte Messung" value+time now read this range-independent raw reading.
    public internal(set) var latestRawMeasurement: Measurement?

    /// Per-source provenance for the current range — computed iOS-side from
    /// `MeasurementsRepository.recent(kind:)` since `/api/measurements/series`
    /// does NOT emit per-point `source` today.
    ///
    /// **Why iOS-side:** the chart-detail screen pulls a measurements page
    /// for the drill-down list anyway, so the round trip is shared. Once
    /// the server exposes per-point provenance (or a `bySource` summary on
    /// the series endpoint), this becomes a fallback for offline.
    ///
    /// Ordered descending by count — chip strip renders dominant source
    /// first. Sorted secondary by source.rawValue for stable ordering when
    /// counts tie.
    public internal(set) var sourceCountsForRange: [SourceCount] = []

    /// Plain-old-data summary of one provenance source's contribution to the
    /// visible range. Used by the SourcesChipStrip.
    public struct SourceCount: Sendable, Equatable, Identifiable {
        public let source: MeasurementSource
        public let count: Int
        public let latest: Date?

        public var id: String {
            source.rawValue
        }

        public init(source: MeasurementSource, count: Int, latest: Date?) {
            self.source = source
            self.count = count
            self.latest = latest
        }
    }

    /// Driver for `task(id:)` — bumped whenever any input that requires a re-fetch changes.
    public var queryKey: String {
        "\(kind.rawValue)-\(range.rawValue)-\(sourceFilter?.rawValue ?? "all")-v\(_queryKeyVersion)"
    }

    // MARK: - Dependencies

    let measurementsRepo: MeasurementsRepository
    let insightsRepo: MetricInsightsRepository
    /// Resolver for the BCP-47 language tag. Sync + Sendable so it can be
    /// captured into a `Task` without strict-concurrency complaints.
    let resolveLocale: @Sendable () -> String
    /// Optional consent gate (PB1 H1). When non-nil and closed, the
    /// Befunde fetch is skipped at the store layer AND the
    /// ``findingsConsentClosed`` flag flips so `FindingsList` can render
    /// the consent-required CTA instead of the generic "empty" state.
    /// Default `nil` keeps unit tests building (gate-not-wired ⇒ legacy
    /// behaviour: hit the repo, which has its own gate when production-wired).
    let consentGate: (@MainActor () -> Bool)?
    /// v0.6.2.x bug-c10 — optional pre-load hook fired BEFORE the server
    /// `series` + `recent` fan-out. The dashboard wires it to the HK
    /// daily-stats refresh for cumulative kinds (Steps + future sum-per-
    /// day metrics) so the chart never paints a stale day-total. `nil`
    /// keeps existing call sites + unit tests building unchanged.
    let preLoadHook: (@Sendable () async -> Void)?
    /// v0.6.2.x bug-c10-ios-direct — closure that resolves today's
    /// HK-direct step total. Honored only for `kind == .steps`. The chart-
    /// detail screen uses this to swap the today series-point value (which
    /// reads from the frozen server `stats:` row for the rest of the day)
    /// for the live HK number. `nil` keeps existing call sites + unit
    /// tests building unchanged.
    private let liveTodayStepsProvider: (@MainActor () -> Double?)?
    /// v0.14 DATA — user height (cm) from the server profile, for the derived
    /// `.bmi` series (BMI = weight_kg / height_m²). `nil` keeps existing call
    /// sites + tests building unchanged; without it the `.bmi` page falls back to
    /// the prior (empty) behaviour rather than mis-charting.
    let heightCmProvider: (@MainActor () -> Double?)?
    var loadTask: Task<Void, Never>?
    private var _queryKeyVersion: Int = 0

    public init(
        kind: MetricKind,
        measurementsRepo: MeasurementsRepository,
        insightsRepo: MetricInsightsRepository,
        resolveLocale: @escaping @Sendable () -> String = {
            Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "de"
        },
        consentGate: (@MainActor () -> Bool)? = nil,
        preLoadHook: (@Sendable () async -> Void)? = nil,
        liveTodayStepsProvider: (@MainActor () -> Double?)? = nil,
        heightCmProvider: (@MainActor () -> Double?)? = nil
    ) {
        self.kind = kind
        self.measurementsRepo = measurementsRepo
        self.insightsRepo = insightsRepo
        self.resolveLocale = resolveLocale
        self.consentGate = consentGate
        self.preLoadHook = preLoadHook
        self.liveTodayStepsProvider = liveTodayStepsProvider
        self.heightCmProvider = heightCmProvider
    }

    /// v0.6.2.x bug-c10-ios-direct — resolved current HK-direct today step
    /// total, or `nil` when the provider returns no value (non-steps kind,
    /// no HK permission, no provider wired). The chart-detail HeroStrip +
    /// ChartCard read this to swap today's bar value out from under the
    /// frozen server snapshot.
    public var liveTodayStepCount: Double? {
        guard kind == .steps else { return nil }
        return liveTodayStepsProvider?()
    }

    // MARK: - Convenience derived state

    /// v0.6.2.x bug-c10-ios-direct — display-side overlay of `series` that
    /// swaps today's bar value out for the HK-direct step total whenever
    /// the live store has a number. `series` itself stays untouched (it's
    /// the wire payload from the server, used by other consumers like
    /// stats / median computation). Only the chart-detail today-bar +
    /// hero reads this overlay. For non-cumulative kinds + non-steps it's
    /// the unmodified `series`.
    public var displaySeries: MeasurementSeries? {
        guard let series else { return nil }
        guard kind == .steps, let liveValue = liveTodayStepCount else { return series }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return series }
        let patched = Self.replacingTodayValue(
            in: series.points,
            liveValue: liveValue,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        // W-B187 (#29) — preserve the server-resolved unit through the today-patch.
        return MeasurementSeries(kind: series.kind, points: patched, stats: series.stats, unit: series.unit)
    }

    /// W-B187 (#29) — display unit label: the server-resolved series `unit`
    /// (v1.16.16 unit-at-source, e.g. glucose `mg/dL` | `mmol/L`) when present,
    /// else the per-`MetricKind` default. The `points`/`stats` are already
    /// converted server-side, so iOS renders this label as-is and never
    /// re-converts. == `kind.unit` for kinds the server doesn't unit-stamp.
    public var displayUnit: String {
        series?.resolvedUnit(for: kind) ?? kind.unit
    }

    /// A360-5 C-1 — unit-aware display label for the chart surfaces.
    ///
    /// The series endpoint converts glucose AT SOURCE (server v1.16.16) but
    /// leaves weight + blood-pressure CANONICAL (kg / mmHg) on the wire. So the
    /// chart hero/stats/callout must flip the LABEL to the user's chosen unit
    /// for weight + BP (the values are converted on-device via
    /// `MetricValueFormatter`), while glucose keeps the server-resolved
    /// `displayUnit` (already the user's unit, value already converted). Every
    /// other kind has no re-unitable family → server label / canonical default.
    public func displayUnit(units: UnitPreferences) -> String {
        switch kind.unitFamily {
        case .weight: units.weight.unitSuffix
        case .bloodPressure: units.bloodPressure.unitSuffix
        case .glucose, .none: displayUnit
        }
    }

    /// A360-5 — converts a SERIES-derived delta (e.g. `deltaVsPriorWindow`) into
    /// the user's unit. The kg→lb / mmHg→kPa / mg/dL→mmol/L conversions are all
    /// purely multiplicative (no offset), so a difference converts with the same
    /// factor as a level. Glucose series points are ALREADY server-converted, so
    /// a glucose delta is already in the user's unit → passthrough.
    public func convertDelta(_ delta: Double, units: UnitPreferences) -> Double {
        switch kind.unitFamily {
        case .weight: units.convertWeight(delta)
        case .bloodPressure: units.convertBloodPressure(delta)
        // Series glucose is pre-converted; `.none` has no conversion.
        case .glucose, .none: delta
        }
    }

    /// A360-5 — converts a SUMMARY-derived canonical value (e.g. the
    /// `avg30LastYear` baseline + its delta) into the user's unit. UNLIKE the
    /// series, the analytics summary is canonical for EVERY family (including
    /// glucose), so glucose converts here too. Multiplicative → safe for both
    /// levels and deltas. The matching label is ``displayUnit(units:)`` for
    /// weight/BP and the glucose suffix for glucose.
    public func convertSummaryValue(_ value: Double, units: UnitPreferences) -> Double {
        switch kind.unitFamily {
        case .weight: units.convertWeight(value)
        case .bloodPressure: units.convertBloodPressure(value)
        case .glucose: units.convertGlucose(value)
        case .none: value
        }
    }

    /// A360-5 — the unit label for SUMMARY-derived values (year-over-year). For
    /// glucose the summary is canonical, so the label is the user's glucose
    /// suffix (`displayUnit` would echo the SERIES unit which is correct here
    /// too, but resolve explicitly for clarity).
    public func summaryDisplayUnit(units: UnitPreferences) -> String {
        switch kind.unitFamily {
        case .weight: units.weight.unitSuffix
        case .bloodPressure: units.bloodPressure.unitSuffix
        case .glucose: units.glucose.unitSuffix
        case .none: displayUnit
        }
    }

    /// v0.8.6 — chart-render points with a `recentInRange` fallback. For the
    /// kinds whose server `/api/measurements/series` endpoint isn't wired
    /// (`kindSupportsSeries == false`: walking speed / step length etc.),
    /// `displaySeries` is forced `nil`, so the chart card used to always
    /// collapse to the "insufficient data" state even though the drill-down
    /// list (fed from `recentInRange`) showed N entries. When `displaySeries`
    /// is present we use its points unchanged; otherwise we synthesize
    /// `SeriesPoint`s from `recentInRange` (chronological) so the chart paints
    /// from the same rows the list shows. Behaviour for series-backed kinds is
    /// unchanged because `displaySeries` is non-nil for those.
    public var chartPoints: [SeriesPoint] {
        if let points = displaySeries?.points {
            return points
        }
        return recentInRange
            .sorted { $0.recordedAt < $1.recordedAt }
            .map { measurement in
                SeriesPoint(
                    id: measurement.id,
                    at: measurement.recordedAt,
                    value: measurement.value.primaryComponent,
                    secondary: nil
                )
            }
    }

    /// Most recent point in the visible series, if any. Drives the hero strip.
    /// v0.6.2.x bug-c10-ios-direct — reads from `displaySeries` so the
    /// HeroStrip's primary number reflects the HK-direct step total when
    /// available.
    ///
    /// v0.14.6 N4 — for every kind EXCEPT `.steps`, the "Letzte Messung"
    /// headline is now the true latest RAW reading (`latestRawMeasurement`),
    /// range-independent, so it no longer jumps to a bucket-average-at-midnight
    /// when the bottom range switches to Month/Year. `.steps` keeps the
    /// `displaySeries` path so the HK-direct cumulative day total still wins.
    public var latestPoint: SeriesPoint? {
        if kind != .steps, let m = latestRawMeasurement { return m.asLatestSeriesPoint }
        return displaySeries?.points.last
    }

    /// Delta of the latest point against the average of the prior window.
    /// Returns `nil` when there's not enough data to compute meaningfully.
    public var deltaVsPriorWindow: Double? {
        guard let points = series?.points, points.count >= 4 else { return nil }
        let half = points.count / 2
        let priorAvg = points.prefix(half).map(\.value).reduce(0, +) / Double(half)
        let recentAvg = points.suffix(points.count - half).map(\.value).reduce(0, +) / Double(points.count - half)
        return recentAvg - priorAvg
    }

    /// Stats are server-computed — we just expose them.
    public var stats: SeriesStats? {
        series?.stats
    }

    /// BP-only: aggregate stats over the diastolic peer (`SeriesPoint.secondary`).
    ///
    /// The server's `SeriesStats` covers the PRIMARY component only (systolic for
    /// blood pressure); the diastolic value lives per-point as
    /// `SeriesPoint.secondary` and is never aggregated server-side. We fold it
    /// on-device from the same rendered series so the BP page can show a second
    /// min/max/mean/median row for diastolic alongside the systolic one.
    public var diastolicStats: SeriesStats? {
        guard kind == .bloodPressure else { return nil }
        let dia = series?.points.compactMap(\.secondary) ?? []
        guard let min = dia.min(), let max = dia.max() else { return nil }
        let mean = dia.reduce(0, +) / Double(dia.count)
        // stdDev is not surfaced by `StatsRow`; pass 0 (the row reads min/mean/max/median).
        return SeriesStats(mean: mean, min: min, max: max, stdDev: 0, count: dia.count)
    }

    /// BP-only: median over the diastolic peer (`SeriesPoint.secondary`),
    /// computed on-device with the same helper as the systolic `median`.
    public var diastolicMedian: Double? {
        guard kind == .bloodPressure else { return nil }
        return Self.median(of: series?.points.compactMap(\.secondary) ?? [])
    }

    /// Locally-computed median over the visible series.
    ///
    /// The server's `SeriesStats` doesn't carry a median field (only mean / min
    /// / max / stdDev), but the median is the more honest "typical" value when
    /// a series has outliers — Apple Health surfaces it in its detail views
    /// for exactly that reason. We compute it on-device from `series.points`
    /// for the rendered window (cheap: ≤ 365 points * one sort).
    public var median: Double? {
        Self.median(of: series?.points.map(\.value) ?? [])
    }

    /// Pure median helper — public so tests can pin the math against
    /// odd/even-count + outlier-resistance corner cases without spinning up
    /// the live store + repos. Mirrors the same algorithm used internally:
    /// sort + middle (or average of two middle values for even counts).
    ///
    /// `nonisolated` so unit tests can call it off the main actor; the
    /// computation is pure (no shared state, no `Self` reads).
    public nonisolated static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // `sourceBreakdown` (always-empty placeholder) was removed in v0.4.1 —
    // the chip strip now binds to `sourceCountsForRange`, computed iOS-side
    // from `MeasurementsRepository.recent(kind:)` until the server adds
    // per-point provenance on `/api/measurements/series`.
}

/// v0.11 — adopt the canonical `HLRangePicker` so the detail chart's period
/// control is the same primitive every other chart uses.
extension ChartDetailStore.Range: HLRangeOption {
    var rangeAccessibilityLabel: String {
        accessibilityLabel
    }
}

// MARK: - N4 latest-raw helper

private extension Measurement {
    /// v0.14.6 N4 — projects this raw measurement to the `SeriesPoint` shape the
    /// HeroStrip "Letzte Messung" headline consumes, carrying the BP diastolic
    /// peer as `secondary`. Lives in an extension so it doesn't count toward the
    /// store's `type_body_length`.
    var asLatestSeriesPoint: SeriesPoint {
        let secondary: Double? = {
            if case let .bloodPressure(_, diastolic) = value { return diastolic }
            return nil
        }()
        return SeriesPoint(
            id: id,
            at: recordedAt,
            value: value.primaryComponent,
            secondary: secondary
        )
    }
}

// MARK: - Cross-source non-summing overlay core

extension ChartDetailStore {
    /// v0.14.8 W-WORKOUT-E2E — pure core of ``displaySeries``. The HK-direct
    /// live value **replaces** today's server datapoint; it is never *added*
    /// to it. This is the iOS half of the cross-source non-summing contract
    /// (the server half is the per-day source-priority ladder pick): when two
    /// providers cover the same day, exactly one value wins — totals must not
    /// inflate. Extracted static so a unit test can pin the replace-not-add
    /// semantics without booting the repo/HK stack.
    static func replacingTodayValue(
        in points: [SeriesPoint],
        liveValue: Double,
        dayStart: Date,
        dayEnd: Date
    ) -> [SeriesPoint] {
        points.map { point in
            guard point.at >= dayStart, point.at < dayEnd else { return point }
            return SeriesPoint(
                id: point.id,
                at: point.at,
                value: liveValue,
                secondary: point.secondary
            )
        }
    }
}
