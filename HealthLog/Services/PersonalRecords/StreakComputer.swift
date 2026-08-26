import Foundation

/// v0.5.4-BF7 — Client-side personal-records derivation.
///
/// **Why:** the server-side `GET /api/personal-records` route exists since
/// v1.4.25 W8d but the detection worker that populates rows lands in
/// v1.4.26 / v1.5. Until then the route returns `[]` for every user. The
/// operator (2026-05-17) confirmed the iOS surface looks broken because of
/// it — "Schritte"-records never appear even though the underlying daily
/// totals are uploaded via the HK-STATS pipeline (V052-A5).
///
/// **What we derive locally:** for the canonical cumulative-kind set
/// (Schritte / Active Energy / Stockwerke / Distanz) we hold the daily
/// series in cache (`/api/measurements/series?kind=steps&days=365`) and
/// compute two record-classes from it:
///
///   - **Best day** — the highest single-day value with its date. Mirrors
///     the operator's expectation of "Bester Tag: 23.412 Schritte am
///     12.04.2026".
///   - **Longest qualifying streak** — the longest run of consecutive days
///     that meet a per-kind threshold (steps ≥ 10.000, active energy ≥
///     500 kcal etc.). Mirrors the operator's "High Streaks"-language and
///     matches the canonical Apple-Health move-streak heuristic.
///
/// **Design:** pure deterministic function over `[SeriesPoint]`. No HK
/// query, no clock, no actor — the caller (`PersonalRecordsStore`) feeds
/// it the cached series and the computer returns a `[PersonalRecordDTO]`
/// in the same wire shape the server will use once the worker ships, so
/// the rendering code path stays single. Unknown / unsupported kinds
/// return empty.
///
/// **Why pure DTOs and not a new client-only type:** the screen renders
/// `PersonalRecordDTO`. Returning the same shape keeps the section /
/// card / accessibility code path untouched + lets the server-shipped
/// records and the client-derived records coexist (server-shipped wins
/// the metric-type bucket once they arrive).
public enum StreakComputer {
    /// Threshold + label config for one cumulative metric-kind. Mirrors
    /// the locked v1.4.30 §12 cumulative-types set + the operator's
    /// canonical streak-thresholds (Apple-Health-Move-style).
    public struct KindConfig: Sendable, Equatable {
        /// Server metric-type-enum value the derived record reports as.
        /// Matches `MetricTypeLocalisation.dictionary` keys so the screen
        /// section header renders the German label without a special
        /// case.
        public let metricType: String
        /// Streak threshold in the same wire-unit as the series points.
        /// `points.value >= threshold` qualifies the day for the streak.
        public let streakThreshold: Double
        /// Wire-unit string — same convention as
        /// `HealthKitCumulativeTypeConfig.wireUnit`.
        public let unit: String
        /// Stable id-prefix used to build deterministic
        /// `PersonalRecordDTO.id` values. The screen treats records as
        /// `Identifiable`, so we need stable ids per derived row.
        public let idPrefix: String

        public init(
            metricType: String,
            streakThreshold: Double,
            unit: String,
            idPrefix: String
        ) {
            self.metricType = metricType
            self.streakThreshold = streakThreshold
            self.unit = unit
            self.idPrefix = idPrefix
        }
    }

    /// Canonical config for the 4 cumulative kinds we have year-of-data
    /// for via the server series-endpoint. Thresholds picked to match
    /// the operator's mental model:
    ///
    ///  - **Steps ≥ 10.000:** Apple-Health-Move-Ring-Equivalent, the
    ///    universal "active day" yardstick.
    ///  - **Active Energy ≥ 500 kcal:** Apple-Watch-default move goal.
    ///  - **Flights ≥ 10:** German body-of-evidence guideline for stair
    ///    health.
    ///  - **Distance ≥ 5.000 m (5 km):** standard "I walked properly"
    ///    benchmark.
    public static let canonicalConfigs: [MetricKind: KindConfig] = [
        .steps: KindConfig(
            metricType: "ACTIVITY_STEPS",
            streakThreshold: 10000,
            unit: "steps",
            idPrefix: "client.steps"
        )
    ]

    /// Pure derivation. `points` is the server-series for one kind in
    /// chronological order (the server emits the series ascending by
    /// `at`). The function tolerates out-of-order input (sorts defensively)
    /// and returns deterministic, stably-id'd `PersonalRecordDTO` rows.
    ///
    /// Returns up to **two** records per kind: `{best-day}` + `{longest
    /// streak ≥ threshold}`. When the user has no qualifying streak the
    /// streak-record is omitted; when the series is empty the result is
    /// empty.
    ///
    /// **v0.5.5.3 REG-9 — daily-sum bucketing:** the server `series`
    /// endpoint emits one `SeriesPoint` per `Measurement` row, not one
    /// per calendar day. Cumulative kinds (steps / energy / distance)
    /// can have multiple rows per day from
    ///   - per-sample legacy ingest (pre-v0.5.2-A5 `HealthKitWireConverter`)
    ///   - multiple HK sources sharing the same day (iPhone + Watch +
    ///     Withings) when the user has more than one device.
    /// Running `max(rowValue)` on the raw stream surfaces the largest
    /// single fragment as the "best day", which is wrong — the operator
    /// reported "8123 Schritte am 15.05.2024" appearing as a record
    /// when the actual all-time best (sum of all source-rows for that
    /// day) was 10843 Schritte am 14.03.2024 (TestFlight build 23,
    /// 2026-05-21). Fix: aggregate rows by `calendar.startOfDay(for:
    /// pt.at)` and sum before ranking. For users on the new
    /// daily-rollup-only pipeline (one row per day per source) the
    /// sum-per-day is the legitimate daily total; for users with mixed
    /// legacy + rollup data the sum can over-count, but the resulting
    /// "best day" is still at least the true daily total — strictly
    /// better than under-counting.
    public static func derive(
        points: [SeriesPoint],
        kind: MetricKind,
        userId: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [PersonalRecordDTO] {
        guard let config = canonicalConfigs[kind], !points.isEmpty else {
            return []
        }
        let dailyTotals = dailyTotals(from: points, calendar: calendar)
        guard !dailyTotals.isEmpty else { return [] }
        var out: [PersonalRecordDTO] = []

        if let best = bestDayRecord(dailyTotals: dailyTotals, config: config, userId: userId, now: now) {
            out.append(best)
        }
        if let streak = longestStreakRecord(
            dailyTotals: dailyTotals,
            config: config,
            userId: userId,
            now: now,
            calendar: calendar
        ) {
            out.append(streak)
        }
        return out
    }

    // MARK: - Daily aggregation

    /// One bucket per calendar day, sorted ascending. `value` is the sum
    /// of every `SeriesPoint` whose `at` falls in that day; `sourceId`
    /// preserves the id of the first row of the winning day so the
    /// best-day record can carry a stable `sourceMeasurementId` for
    /// log-tracing. Zero-value buckets are filtered out — they mean
    /// "no data" and would dominate a hypothetical `.min` direction.
    struct DailyTotal: Equatable {
        let day: Date
        let value: Double
        let sourceId: String?
    }

    static func dailyTotals(
        from points: [SeriesPoint],
        calendar: Calendar
    ) -> [DailyTotal] {
        var bucketSum: [Date: Double] = [:]
        var bucketSourceId: [Date: String] = [:]
        for pt in points {
            let day = calendar.startOfDay(for: pt.at)
            bucketSum[day, default: 0] += pt.value
            if bucketSourceId[day] == nil {
                bucketSourceId[day] = pt.id
            }
        }
        return bucketSum.keys.sorted().compactMap { day in
            let total = bucketSum[day] ?? 0
            guard total > 0 else { return nil }
            return DailyTotal(day: day, value: total, sourceId: bucketSourceId[day])
        }
    }

    // MARK: - Best-day

    /// Highest daily-total across the year window. Stable id is
    /// `<prefix>.best`, achievedAt is the day-start of the winning bucket.
    static func bestDayRecord(
        dailyTotals: [DailyTotal],
        config: KindConfig,
        userId: String,
        now: Date
    ) -> PersonalRecordDTO? {
        guard let best = dailyTotals.max(by: { $0.value < $1.value }) else { return nil }
        return PersonalRecordDTO(
            id: "\(config.idPrefix).best",
            userId: userId,
            metricType: config.metricType,
            metricSlot: "Bester Tag",
            direction: .max,
            value: best.value,
            unit: config.unit,
            achievedAt: best.day,
            sourceMeasurementId: best.sourceId,
            source: "HEALTHLOG_CLIENT",
            externalId: nil,
            createdAt: now
        )
    }

    // MARK: - Streak

    /// Longest consecutive-calendar-day run where the day's *total*
    /// (sum across all rows for that day) is ≥ threshold. Consecutive
    /// is decided on the user-TZ calendar day, so a missing day breaks
    /// the run.
    static func longestStreakRecord(
        dailyTotals: [DailyTotal],
        config: KindConfig,
        userId: String,
        now: Date,
        calendar: Calendar
    ) -> PersonalRecordDTO? {
        let dayKeys: [(Date, Double)] = dailyTotals
            .filter { $0.value >= config.streakThreshold }
            .map { ($0.day, $0.value) }
        guard !dayKeys.isEmpty else { return nil }

        // Walk the series, group consecutive days, track the longest run.
        var bestStart: Date = dayKeys[0].0
        var bestEnd: Date = dayKeys[0].0
        var bestLength = 1
        var currentStart: Date = dayKeys[0].0
        var currentEnd: Date = dayKeys[0].0
        var currentLength = 1

        for idx in 1 ..< dayKeys.count {
            let prev = dayKeys[idx - 1].0
            let day = dayKeys[idx].0
            if let next = calendar.date(byAdding: .day, value: 1, to: prev), calendar.isDate(next, inSameDayAs: day) {
                currentEnd = day
                currentLength += 1
            } else {
                currentStart = day
                currentEnd = day
                currentLength = 1
            }
            if currentLength > bestLength {
                bestLength = currentLength
                bestStart = currentStart
                bestEnd = currentEnd
            }
        }

        // A single-day run is not a "streak" in the operator's mental
        // model — only surface when there are 2+ consecutive qualifying
        // days. This also keeps the section single-row when the best
        // day is exactly the threshold and no run formed.
        guard bestLength >= 2 else { return nil }

        return PersonalRecordDTO(
            id: "\(config.idPrefix).streak",
            userId: userId,
            metricType: config.metricType,
            metricSlot: "Längste Serie ≥ \(formatThreshold(config.streakThreshold)) (\(bestLength) Tage)",
            direction: .max,
            value: Double(bestLength),
            unit: "Tage",
            achievedAt: bestEnd,
            sourceMeasurementId: nil,
            source: "HEALTHLOG_CLIENT",
            externalId: dateRangeKey(from: bestStart, to: bestEnd),
            createdAt: now
        )
    }

    // MARK: - Helpers

    /// Thousands-separated, locale-aware threshold label — `10000` →
    /// `"10.000"` in German locale. Kept private so the screen never has
    /// to round-trip through this code path.
    private static func formatThreshold(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Compact range-key embedded as `externalId` so future inspection in
    /// logs can pinpoint which window produced the record without a
    /// second query. Format: `streak:YYYY-MM-DD..YYYY-MM-DD`.
    private static func dateRangeKey(from start: Date, to end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "streak:\(formatter.string(from: start))..\(formatter.string(from: end))"
    }
}
