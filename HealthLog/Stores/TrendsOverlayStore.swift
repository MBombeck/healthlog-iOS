import Foundation
import Observation

/// State for the Apple-Health-style multi-metric overlay chart shown at the
/// top of `ChartsScreen` ("Trends" tab).
///
/// **Design rationale (v0.4.0 charts marathon, Stream Charlie):**
/// The Trends entry-point used to be a flat list of per-metric mini-cards.
/// Apple Health surfaces a "Highlights" overlay at the very top — multiple
/// metrics normalised onto a single chart so the user can spot
/// correlations at a glance (e.g. weight + resting-pulse trending up
/// together, or BP recovering as sleep improves). This store owns that
/// overlay.
///
/// **Normalisation strategy:**
/// Each metric has wildly different units (weight kg ≈ 70-90, BP ≈ 120/80,
/// pulse ≈ 60-100). Plotting raw values on a shared axis would have weight
/// crushed against the bottom. Instead, each series is z-score-normalised
/// against its own window (so the chart shows "this metric vs its own
/// typical range" — Apple's pattern). The y-axis is unit-less by design.
///
/// **Lifecycle:** one shared instance per Trends screen mount. Period
/// changes and metric-toggle changes drive re-fetch via `queryKey`.
@MainActor
@Observable
public final class TrendsOverlayStore {
    // MARK: - Range

    public enum Range: Int, CaseIterable, Identifiable, Sendable {
        case week = 7
        case month = 30
        case sixMonths = 180
        case year = 365

        public var id: Int {
            rawValue
        }

        public var label: String {
            switch self {
            case .week: "W"
            case .month: "M"
            case .sixMonths: "6M"
            case .year: String(localized: "range.label.year", defaultValue: "Y")
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .week: String(localized: "Week")
            case .month: String(localized: "Month")
            case .sixMonths: String(localized: "6 months")
            case .year: String(localized: "Year")
            }
        }
    }

    /// Display mode for the overlay chart.
    ///
    /// - `.raw` — exactly one metric selected. The chart plots raw values
    ///   with the metric's native unit on the y-axis (kg, mmHg, bpm). This
    ///   is the Apple-Health-style "single-metric drill-in" — the loudest
    ///   v0.4.0 user complaint ("Gewicht steigt+faellt ohne kg") was that
    ///   the z-score normalisation kicked in even with one metric.
    /// - `.zScore` — two or more metrics selected. Each series is
    ///   z-score-normalised onto a unit-less shared axis so the user can
    ///   compare trends across wildly different units (the original brief
    ///   for the overlay).
    public enum Mode: Sendable, Equatable {
        case raw(kind: MetricKind)
        case zScore
    }

    /// Period averaging granularity applied to raw-mode plots. Driven by the
    /// chart toolbar segmented control. `.none` = plot all raw points.
    ///
    /// All averaging happens on-device from `MeasurementSeries.points`
    /// (the server doesn't expose a `?aggregate=` knob today — when it does,
    /// the iOS-side bucketing can become a fallback for offline mode).
    public enum Averaging: String, Sendable, CaseIterable, Identifiable {
        case none
        case daily
        case weekly
        case monthly

        public var id: String {
            rawValue
        }

        public var label: String {
            switch self {
            case .none: String(localized: "trends.averaging.raw")
            case .daily: String(localized: "Day")
            case .weekly: String(localized: "Week")
            case .monthly: String(localized: "Month")
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .none: String(localized: "trends.averaging.raw.a11y")
            case .daily: String(localized: "trends.averaging.daily.a11y")
            case .weekly: String(localized: "trends.averaging.weekly.a11y")
            case .monthly: String(localized: "trends.averaging.monthly.a11y")
            }
        }
    }

    /// A z-score-normalised series with the points retained for axis labels.
    public struct NormalisedSeries: Identifiable, Sendable {
        public let kind: MetricKind
        public let points: [SeriesPoint]
        /// `(date, zScore)` ready to plot on the overlay's unit-less y-axis.
        public let normalisedPoints: [NormalisedPoint]

        public var id: String {
            kind.rawValue
        }
    }

    public struct NormalisedPoint: Sendable, Hashable {
        public let at: Date
        /// z-score: (value - mean) / stdDev (clamped to ±3 to keep extreme
        /// outliers from rescaling the y-axis off the chart).
        public let z: Double
        public let rawValue: Double
    }

    // MARK: - Inputs

    public var range: Range = .month {
        didSet { if range != oldValue { _queryKeyVersion += 1 } }
    }

    /// User-toggled set — drives which series render. The overlay starts with
    /// BP+Weight+Pulse selected (the three vital signs every user logs); the
    /// user adds Glucose / SpO2 / Sleep etc. via the chip row.
    public var selectedMetrics: Set<MetricKind> = TrendsOverlayStore.defaultSelection {
        didSet { if selectedMetrics != oldValue { _queryKeyVersion += 1 } }
    }

    /// Initial selection the overlay opens with — the three vital signs
    /// nearly every user logs (BP / Weight / Pulse). Exposed as a static
    /// `let` so `AppContainer+Prefetch` can warm the SWR cache for the
    /// exact same set without hardcoding the defaults in two places
    /// (v0.6.2.3 F2-CHARTLAG).
    ///
    /// `nonisolated` so the prefetch (off-main detached task) can read
    /// the catalogue without an actor hop.
    public nonisolated static let defaultSelection: Set<MetricKind> = [
        .bloodPressure, .weight, .pulse
    ]

    /// Period-averaging granularity for raw-mode (single-metric) plots. Has
    /// no effect in z-score mode. Default `.none` mirrors Apple Health's
    /// "Roh" affordance — the user opts into aggregation explicitly.
    public var averaging: Averaging = .none

    // MARK: - Outputs

    public private(set) var normalisedSeries: [NormalisedSeries] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    public var queryKey: String {
        let sortedKinds = selectedMetrics.map(\.rawValue).sorted().joined(separator: ",")
        return "\(range.rawValue)-\(sortedKinds)-v\(_queryKeyVersion)"
    }

    /// Metrics the user can pick from in the chip row. **v0.5.5.2** — pruned
    /// to the 10 kinds the server's `/api/measurements/series` Zod enum
    /// accepts (W-DATA-FLOW-AUDIT BLOCKER #2). Selecting an unsupported
    /// kind used to throw 400 inside `withThrowingTaskGroup`, which
    /// rethrew and aborted the entire overlay — operator-perceived
    /// "Trends doesn't work" the moment the user toggled Resting Heart-
    /// rate / HRV / VO2max.
    ///
    /// Server-accepted kinds (mirror `src/lib/measurement-kinds.ts`):
    /// `weight, bloodPressure, pulse, bodyFat, glucose, sleep, steps,
    /// bodyWater (totalBodyWater server-side), boneMass, spo2
    /// (oxygenSaturation server-side)`.
    ///
    /// Kinds that the iOS DTO exposes but the server enum currently
    /// rejects: `restingHeartRate, hrv, vo2Max, bodyTemperature,
    /// walkingSpeed, walkingAsymmetry, walkingStepLength, bmi`. They
    /// stay OUT of the chip row until the server enum picks them up.
    /// The runtime guard in `load()` skips any leak-through case
    /// (logged + ignored) so a future regression doesn't abort the
    /// whole overlay.
    ///
    /// `nonisolated` so the chip row + unit tests can read the catalogue
    /// without an actor hop; the array is a `let` of value types.
    public nonisolated static let availableMetrics: [MetricKind] = [
        .bloodPressure, .weight, .pulse, .glucose,
        .sleep, .steps, .spo2, .bodyFat, .bodyWater, .boneMass
    ]

    /// **v0.5.5.2 server-enum gate.** Kinds the server's
    /// `/api/measurements/series` endpoint accepts as of v1.4.39.4. Used
    /// by `load()` to silently skip any leak-through unsupported kind so
    /// a single 400 doesn't abort the whole overlay. Keep in lockstep
    /// with `availableMetrics` — same membership, hash-set lookup.
    nonisolated static let serverSupportedKinds: Set<MetricKind> = Set(availableMetrics)

    // MARK: - Dependencies

    private let repo: MeasurementsRepository
    private var _queryKeyVersion: Int = 0
    private var loadTask: Task<Void, Never>?

    public init(repo: MeasurementsRepository) {
        self.repo = repo
    }

    // MARK: - Loading

    public func load() async {
        loadTask?.cancel()
        let currentRange = range
        let currentSelection = selectedMetrics
        let task = Task { [repo] in
            isLoading = true
            error = nil
            defer { isLoading = false }
            do {
                // Concurrent fetch across selected metrics. Each call hits
                // `/api/measurements/series?kind=…&days=…` — the server-side
                // endpoint is the bottleneck, but parallelising still wins
                // a real-world second on a 4-metric selection.
                //
                // v0.5.5.2 — filter against `serverSupportedKinds` BEFORE
                // dispatching the task group. A single 400 inside
                // `withThrowingTaskGroup` rethrows + aborts every other
                // task → operator-perceived "Trends broken". Skipping
                // unsupported kinds at the dispatch site keeps the rest
                // of the overlay alive.
                let kinds = currentSelection.filter { Self.serverSupportedKinds.contains($0) }
                if kinds.count < currentSelection.count {
                    let dropped = currentSelection.subtracting(kinds).map(\.rawValue).sorted().joined(separator: ",")
                    // MetricKind enum cases only — operator-grade.
                    // swiftlint:disable:next hllog_public_privacy_interpolation
                    HLLog.api.notice("TrendsOverlay: skipping server-unsupported kinds \(dropped, privacy: .public)")
                }
                let results = try await withThrowingTaskGroup(of: (MetricKind, MeasurementSeries).self) { group in
                    for kind in kinds {
                        group.addTask { [repo] in
                            let series = try await repo.series(kind: kind, days: currentRange.rawValue)
                            return (kind, series)
                        }
                    }
                    var collected: [(MetricKind, MeasurementSeries)] = []
                    for try await pair in group {
                        collected.append(pair)
                    }
                    return collected
                }
                if Task.isCancelled { return }
                normalisedSeries = results
                    .sorted { $0.0.rawValue < $1.0.rawValue }
                    .map { kind, series in
                        Self.normalise(kind: kind, series: series)
                    }
            } catch let err as HLError {
                if !Task.isCancelled { error = err }
            } catch {
                if !Task.isCancelled { self.error = .unknown(String(describing: error)) }
            }
        }
        loadTask = task
        await task.value
    }

    public func toggle(_ kind: MetricKind) {
        if selectedMetrics.contains(kind) {
            selectedMetrics.remove(kind)
        } else {
            selectedMetrics.insert(kind)
        }
    }

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — drop the previous user's series
    /// data + chart configuration on logout. Cancelling the load task first
    /// keeps a pre-logout fetch from re-painting stale series afterwards.
    public func clearOnLogout() {
        loadTask?.cancel()
        loadTask = nil
        normalisedSeries = []
        isLoading = false
        error = nil
        range = .month
        selectedMetrics = Self.defaultSelection
        averaging = .none
    }

    // MARK: - Mode

    /// `.raw` when exactly one metric is selected, `.zScore` otherwise.
    ///
    /// **Rationale (v0.4.1 user fix):** the overlay z-score-normalises so
    /// disparate units can share an axis — useful for n ≥ 2 metrics. With
    /// one metric the normalisation destroys the value the user wanted
    /// (the actual kg / mmHg / bpm reading). Apple Health applies the same
    /// heuristic: pin a single metric → native unit, pin multiple → unit-less.
    public var mode: Mode {
        if selectedMetrics.count == 1, let only = selectedMetrics.first {
            return .raw(kind: only)
        }
        return .zScore
    }

    /// The single-metric series ready for raw plotting. `nil` outside raw mode.
    public var rawSeries: NormalisedSeries? {
        guard case .raw = mode else { return nil }
        return normalisedSeries.first
    }

    /// Raw points after optional period averaging. Always returns the
    /// rendering-ready set for raw mode — when `averaging == .none` this is
    /// the full point list; otherwise it's bucketed by Calendar.
    ///
    /// `nonisolated` so the view + tests can read without an actor hop;
    /// pure aggregation over the stored series.
    public var aggregatedRawPoints: [SeriesPoint] {
        guard let series = rawSeries else { return [] }
        return Self.aggregate(points: series.points, by: averaging)
    }

    // MARK: - Period averaging

    /// Bucket raw points by Calendar period and return the per-bucket mean
    /// (plus secondary-mean for BP). Pure helper — public so unit tests can
    /// pin boundary behaviour (week boundaries, single-bucket edge cases).
    public nonisolated static func aggregate(
        points: [SeriesPoint],
        by averaging: Averaging,
        calendar: Calendar = .current
    ) -> [SeriesPoint] {
        guard averaging != .none else { return points }
        guard !points.isEmpty else { return [] }
        let component: Calendar.Component = switch averaging {
        case .none: .day // unreachable (guarded above)
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
        // Group by the start-of-period; preserve sort order by walking the
        // input and emitting one aggregated point per bucket.
        var bucketOrder: [Date] = []
        var bucketed: [Date: [SeriesPoint]] = [:]
        for p in points {
            guard let interval = calendar.dateInterval(of: component, for: p.at) else { continue }
            let bucketStart = interval.start
            if bucketed[bucketStart] == nil {
                bucketed[bucketStart] = []
                bucketOrder.append(bucketStart)
            }
            bucketed[bucketStart]?.append(p)
        }
        return bucketOrder.compactMap { start -> SeriesPoint? in
            guard let group = bucketed[start], !group.isEmpty else { return nil }
            let count = Double(group.count)
            let mean = group.map(\.value).reduce(0, +) / count
            let secondary: Double? = {
                let secondaries = group.compactMap(\.secondary)
                guard !secondaries.isEmpty else { return nil }
                return secondaries.reduce(0, +) / Double(secondaries.count)
            }()
            // Anchor bucket label at the period midpoint so the chart x-axis
            // tick reads "week of 13–19 May" rather than "13 May".
            guard let interval = calendar.dateInterval(of: component, for: start) else {
                return SeriesPoint(id: "agg-\(start.timeIntervalSince1970)", at: start, value: mean, secondary: secondary)
            }
            let mid = Date(timeIntervalSince1970: (interval.start.timeIntervalSince1970 + interval.end.timeIntervalSince1970) / 2)
            return SeriesPoint(id: "agg-\(start.timeIntervalSince1970)", at: mid, value: mean, secondary: secondary)
        }
    }

    // MARK: - Normalisation

    /// Maps raw `MeasurementSeries` to unit-less z-scores clamped to ±3.
    ///
    /// Apple Health's overlay y-axis is intentionally unlabelled; the
    /// reader's brain compares slopes, not absolutes. Clamping to ±3 keeps
    /// a single outlier from rescaling everything else into the noise floor.
    ///
    /// `nonisolated` so unit tests + background tasks can call it; the
    /// function is pure.
    nonisolated static func normalise(kind: MetricKind, series: MeasurementSeries) -> NormalisedSeries {
        let mean = series.stats.mean
        let std = series.stats.stdDev > 0 ? series.stats.stdDev : max(abs(mean) * 0.01, 1)
        let points = series.points.map { point -> NormalisedPoint in
            let raw = point.value
            let rawZ = (raw - mean) / std
            let clamped = min(max(rawZ, -3), 3)
            return NormalisedPoint(at: point.at, z: clamped, rawValue: raw)
        }
        return NormalisedSeries(kind: kind, points: series.points, normalisedPoints: points)
    }
}

/// v0.11 — adopt the canonical `HLRangePicker` so the Trends overlay's period
/// control is the same primitive every other chart uses.
extension TrendsOverlayStore.Range: HLRangeOption {
    var rangeAccessibilityLabel: String {
        accessibilityLabel
    }
}
