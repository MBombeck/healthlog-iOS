import Foundation

/// **Same-Time-Baseline (CU-30 / C5, server v1.34.0).** The typed projection of
/// the `SAME_TIME_BASELINE` arm of the shared `Derived<T>` union
/// (`GET /api/insights/derived?metric=SAME_TIME_BASELINE&type=<MeasurementType>`,
/// `src/lib/insights/derived/same-time-baseline.ts`).
///
/// ## What this surface answers
///
/// A cumulative metric has no meaningful "latest reading". Four thousand steps
/// is a good day at nine in the morning and a poor one at ten at night. So the
/// server compares today's running total against the operator's own typical
/// standing **at the same hour of day**, over a 28-day window.
///
/// ## Nothing is recomputed here, and nothing is projected
///
/// Every number below is server-computed and inspectable. iOS renders them and
/// does **not** recompute a single one — and in particular derives **no
/// end-of-day forecast**. The server deliberately ships none, because an
/// extrapolation from a partial day would be a guess, and this surface exists
/// precisely to replace guessing (`same-time-baseline.ts:24-27`).
public enum SameTimeBaselineMetric {
    /// The registered derived-metric id (`registry.ts:359-367`).
    public static let id = "SAME_TIME_BASELINE"
    /// Usable history days the server requires before it computes a value
    /// (`registry.ts:183`). Below this the gated `learning_usual_day` arm ships
    /// — the normal state of the first two weeks, not a defect.
    public static let requiredHistoryDays = 14
}

// MARK: - Supported types

/// The four cumulative measurement types the server baselines
/// (`SAME_TIME_BASELINE_TYPES`, `registry.ts:145-155`).
///
/// **Not runtime-discoverable.** `GET /api/meta/capabilities` exposes
/// `derivedMetricIds` and `vitalsBaselineTypes` but *not* this set, so the four
/// values are pinned in the client. A `type` outside the set is not a transport
/// error: the server answers `200` with the gated
/// ``SameTimeBaselineGate/unsupportedType`` arm.
public enum SameTimeBaselineType: String, CaseIterable, Sendable, Identifiable, Codable {
    case activitySteps = "ACTIVITY_STEPS"
    case activeEnergyBurned = "ACTIVE_ENERGY_BURNED"
    case walkingRunningDistance = "WALKING_RUNNING_DISTANCE"
    case flightsClimbed = "FLIGHTS_CLIMBED"

    public var id: String {
        rawValue
    }

    /// The server's own default when `type` is omitted
    /// (`dispatch.ts:213-235`) — steps.
    public static let `default`: SameTimeBaselineType = .activitySteps

    /// The batch token this type rides in on
    /// (`GET /api/insights/derived/batch?metrics=SAME_TIME_BASELINE:<type>`).
    /// The batch response map is keyed by exactly this string
    /// (`batch/route.ts:239-242`).
    public var batchToken: String {
        "\(SameTimeBaselineMetric.id):\(rawValue)"
    }

    /// The app's own metric routing key — lets the card sit on the matching
    /// per-metric Insights page.
    public var metricKind: MetricKind {
        switch self {
        case .activitySteps: .steps
        case .activeEnergyBurned: .activeEnergy
        case .walkingRunningDistance: .distanceWalkingRunning
        case .flightsClimbed: .flightsClimbed
        }
    }
}

// MARK: - The `ok` arm

/// The decoded `ok`-arm payload, exactly as the server emits it
/// (`same-time-baseline.ts:240-259`). Every field is carried through; none is
/// re-derived.
public struct SameTimeBaseline: Sendable, Equatable {
    /// Where today's running total stands against the typical band
    /// (`same-time-baseline.ts:71`).
    public enum Band: String, Sendable {
        case below, within, above
    }

    public let type: SameTimeBaselineType
    /// Display unit resolved server-side (falls back to `"count"`).
    public let unit: String
    /// IANA zone the day was cut in (from the user row, not the device).
    public let timezone: String
    /// Local calendar day, `YYYY-MM-DD`.
    public let dateKey: String
    /// The last **completed** local hour.
    ///
    /// **Range is 0…22, never 23.** The doc comment on the server says 0–23,
    /// but the computation is `hourOfDayForUserTz(now, tz) - 1` over a 0…23
    /// source (`same-time-baseline.ts:175`), so hour 23 is never the anchor and
    /// the curves are 1…23 points long — never 24. A client that hard-plans 24
    /// points is wrong.
    public let asOfHour: Int
    /// Today's cumulative total at ``asOfHour``. Unrounded.
    public let todayValue: Double
    /// The window median at ``asOfHour``. Unrounded — a median of integers can
    /// legitimately be `x.5`.
    public let typicalValue: Double
    /// Lower edge of the typical band; collapses onto ``typicalValue`` when the
    /// band could not be formed (`same-time-baseline.ts:222`).
    public let typicalLow: Double
    /// Upper edge of the typical band; same collapse rule (`:223`).
    public let typicalHigh: Double
    /// Signed `today − typical`, server-computed.
    public let delta: Double
    /// Today as a percentage of typical, rounded server-side.
    ///
    /// **`nil` on a perfectly healthy `ok` arm.** It is `nil` exactly when the
    /// typical total at this hour is zero (`same-time-baseline.ts:252-253`) —
    /// the normal state at 05:00, an undefined ratio, not a hundred percent and
    /// not a failure. The rest of the payload is fully populated, so a missing
    /// percentage must never read as "metric unavailable".
    public let percentOfTypical: Int?
    public let band: Band
    /// Today's cumulative curve, hour `0 … asOfHour`, index-aligned with
    /// ``typicalCurve``. Bare numbers, never null, monotonically non-decreasing.
    public let todayCurve: [Double]
    /// The per-hour median across the window's usable days, same length and
    /// index alignment. Monotone too, but no single real day.
    public let typicalCurve: [Double]
    /// Usable history days behind the value — on the `ok` arm always ≥ 14.
    public let baselineDays: Int
    /// The trailing window, 28 days; not overridable over HTTP.
    public let windowDays: Int

    public init(
        type: SameTimeBaselineType,
        unit: String,
        timezone: String,
        dateKey: String,
        asOfHour: Int,
        todayValue: Double,
        typicalValue: Double,
        typicalLow: Double,
        typicalHigh: Double,
        delta: Double,
        percentOfTypical: Int?,
        band: Band,
        todayCurve: [Double],
        typicalCurve: [Double],
        baselineDays: Int,
        windowDays: Int
    ) {
        self.type = type
        self.unit = unit
        self.timezone = timezone
        self.dateKey = dateKey
        self.asOfHour = asOfHour
        self.todayValue = todayValue
        self.typicalValue = typicalValue
        self.typicalLow = typicalLow
        self.typicalHigh = typicalHigh
        self.delta = delta
        self.percentOfTypical = percentOfTypical
        self.band = band
        self.todayCurve = todayCurve
        self.typicalCurve = typicalCurve
        self.baselineDays = baselineDays
        self.windowDays = windowDays
    }

    /// `true` when both curves carry exactly `asOfHour + 1` index-aligned
    /// points — the server's own invariant. A payload that violates it is not
    /// charted (the numbers still render), so a future shape change degrades
    /// quietly instead of drawing a misaligned comparison.
    public var curvesAreAligned: Bool {
        todayCurve.count == asOfHour + 1 && typicalCurve.count == asOfHour + 1
    }

    /// The chartable hour rows, or `[]` when the alignment invariant fails.
    public var curvePoints: [Point] {
        guard curvesAreAligned else { return [] }
        return (0 ... asOfHour).map {
            Point(hour: $0, today: todayCurve[$0], typical: typicalCurve[$0])
        }
    }

    /// One hour of the two index-aligned curves.
    public struct Point: Sendable, Equatable, Identifiable {
        public let hour: Int
        public let today: Double
        public let typical: Double

        public var id: Int {
            hour
        }

        public init(hour: Int, today: Double, typical: Double) {
            self.hour = hour
            self.today = today
            self.typical = typical
        }
    }

    /// The unit to put next to a number. The server's `"count"` is a technical
    /// placeholder, not a display unit (steps and flights carry none), so it
    /// resolves through the app's own kind unit; anything else the server names
    /// is rendered verbatim.
    public var displayUnit: String {
        unit == "count" ? type.metricKind.unit : unit
    }

    /// The dismiss identity of the matching digest rail card
    /// (`priority-item-key.ts:52-57`). The hour is deliberately absent: the
    /// card's numbers move through the day, and an hourly key would undo a
    /// dismissal every hour. Dismissing means "not today".
    public var railItemKey: String {
        Self.railItemKey(dateKey: dateKey, type: type)
    }

    /// Builds the rail dismiss key without a decoded payload.
    public static func railItemKey(dateKey: String, type: SameTimeBaselineType) -> String {
        "same_time_baseline:\(dateKey):\(type.rawValue)"
    }
}

// MARK: - The gated arm

/// The gated (`status: "insufficient"`) reasons this metric can return.
///
/// **These are the normal case, not the failure case.** Two of them are
/// long-lived states of a perfectly healthy account, and neither may render as
/// an error.
public enum SameTimeBaselineGate: Sendable, Equatable {
    /// Fewer than 14 usable days in the 28-day window — the standing state of
    /// the first two weeks. `historyDays` carries the counter so "N von 14" is
    /// renderable (`same-time-baseline.ts:197-199`).
    case learningUsualDay(historyDays: Int)
    /// No intraday rows at all for today. **A permanent state** for accounts
    /// whose activity arrives as a daily total (Fitbit, Withings, Polar) and
    /// never had an intraday stream. Honest absence — never an error
    /// (`same-time-baseline.ts:191-195`).
    case noIntradayToday
    /// Local time is before 01:00, so no hour has completed yet
    /// (`same-time-baseline.ts:176`).
    case dayTooYoung
    /// The requested `type` is not one of the four cumulative types
    /// (`dispatch.ts:233`).
    case unsupportedType
    /// The shared stub reason (`dispatch.ts:66`). Structurally unreachable for
    /// this metric at v1.34.2, tolerated defensively.
    case notImplemented
    /// A reason literal this client build does not model — rendered as the same
    /// calm "not yet" state rather than an error.
    case unknown(String)

    public init(reason: String, historyDays: Int) {
        switch reason {
        case "learning_usual_day": self = .learningUsualDay(historyDays: historyDays)
        case "no_intraday_today": self = .noIntradayToday
        case "day_too_young": self = .dayTooYoung
        case "unsupported_baseline_type": self = .unsupportedType
        case "not_implemented": self = .notImplemented
        default: self = .unknown(reason)
        }
    }

    /// The wire literal, so a gate round-trips for logging/tests.
    public var reason: String {
        switch self {
        case .learningUsualDay: "learning_usual_day"
        case .noIntradayToday: "no_intraday_today"
        case .dayTooYoung: "day_too_young"
        case .unsupportedType: "unsupported_baseline_type"
        case .notImplemented: "not_implemented"
        case let .unknown(raw): raw
        }
    }
}

// MARK: - Projection off the shared union

public extension DerivedMetricDTO {
    /// The `SAME_TIME_BASELINE` `ok` payload, or `nil` when this envelope is
    /// not that metric, is gated, or is missing a field the server always
    /// sends on the `ok` arm.
    ///
    /// `percentOfTypical` is intentionally NOT required — it is nullable on a
    /// healthy `ok` arm.
    var sameTimeBaseline: SameTimeBaseline? {
        guard metric == SameTimeBaselineMetric.id, isOK, let value else { return nil }
        guard
            let rawType = value.type,
            let type = SameTimeBaselineType(rawValue: rawType),
            let unit = value.unit,
            let timezone = value.timezone,
            let dateKey = value.dateKey,
            let asOfHour = value.asOfHour,
            let todayValue = value.todayValue,
            let typicalValue = value.typicalValue,
            let typicalLow = value.typicalLow,
            let typicalHigh = value.typicalHigh,
            let delta = value.delta,
            let rawBand = value.band,
            let band = SameTimeBaseline.Band(rawValue: rawBand),
            let todayCurve = value.todayCurve,
            let typicalCurve = value.typicalCurve,
            let baselineDays = value.baselineDays,
            let windowDays = value.windowDays else { return nil }
        return SameTimeBaseline(
            type: type,
            unit: unit,
            timezone: timezone,
            dateKey: dateKey,
            asOfHour: asOfHour,
            todayValue: todayValue,
            typicalValue: typicalValue,
            typicalLow: typicalLow,
            typicalHigh: typicalHigh,
            delta: delta,
            percentOfTypical: value.percentOfTypical,
            band: band,
            todayCurve: todayCurve,
            typicalCurve: typicalCurve,
            baselineDays: baselineDays,
            windowDays: windowDays
        )
    }

    /// The gated arm of a `SAME_TIME_BASELINE` envelope, or `nil` when the
    /// envelope is a different metric or carries a value.
    var sameTimeBaselineGate: SameTimeBaselineGate? {
        guard metric == SameTimeBaselineMetric.id, !isOK else { return nil }
        return SameTimeBaselineGate(
            reason: reason ?? "",
            historyDays: coverage.historyDays
        )
    }
}
