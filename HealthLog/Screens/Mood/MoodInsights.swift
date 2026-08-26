import Foundation

/// v0.10.0 W-Mood-A — the pure mood-analysis computation engine.
///
/// Ports MoodLog's `statistics-compute.ts` oracle (server repo
/// `~/Projects/MoodLog/src/lib/statistics-compute.ts`) into a `Sendable`,
/// I/O-free value type so the More → Stimmung analysis screen works **fully
/// offline** — every stat derives from the cached `MoodEntry` list iOS already
/// holds. `/api/mood/analytics` is an authoritative ENRICHMENT/override when
/// online (see `MoodAnalyticsEnrichment`), never a hard dependency.
///
/// **The shared spine** is `dailyAvg`: collapse all entries to **one value per
/// local day** (`mean(score of entries that day)`, keyed by
/// `Calendar.startOfDay`). Heatmap, trend MA + mean, stability, and the
/// correlation detectors all consume `dailyAvg`; only tag-insight needs
/// per-entry tags. This mirrors MoodLog's "average same-day entries first"
/// rule (`statistics-compute.ts` L64-87, L225-235).
///
/// Each card is **sample-gated** — when samples/effect are insufficient the
/// corresponding field is `nil` and the host omits that surface silently
/// (no empty cards). Gating IS the restraint mechanism per W-MOOD-BRIEF.
///
/// Unit-tested vs fixtures in `MoodInsightsTests`.
struct MoodInsights: Equatable, Sendable {
    /// One average score per local day, ascending by day. The spine.
    let dailyAverages: [MoodDailyAverage]
    /// Most-recent entry score (1…5), `nil` when no entries.
    let latestScore: Int?
    /// Mean of the daily averages over the whole window, `nil` when empty.
    let mean: Double?
    /// 30-day average of daily averages (trailing from `now`), `nil` when none.
    let avg30: Double?
    /// Linear-regression slopes (score units/day) over the trailing 7/30/90 day
    /// windows. `nil` when the window has < 2 daily points.
    let slope7: Double?
    let slope30: Double?
    let slope90: Double?
    /// Prior-period 30-day mean (the 30 days BEFORE the latest 30), for the
    /// zone-1 "+0,4 vs Vormonat" delta. `nil` when the prior window is empty.
    let avg30PriorPeriod: Double?
    /// 0…100 stability score (inverse std-dev of daily averages), with band +
    /// sentence. `nil` when < `stabilityMinDays` daily points.
    let stability: MoodStability?
    /// Tag → avg-mood delta chips, sample-gated + sorted by |delta| desc.
    let tagDeltas: [MoodTagDelta]
    /// The full gated correlation-detector set; each self-suppresses.
    let patterns: [MoodPattern]
    /// Total entry count in the window (multi-entry days counted per entry).
    let entryCount: Int
    /// Distinct days with at least one entry.
    let dayCount: Int

    /// Minimum daily-average days required before the stability gauge renders.
    static let stabilityMinDays = 7

    /// The all-nil insight set. This is the value ``compute(entries:now:calendar:enrichment:)``
    /// has always returned for an empty history; naming it lets a render that is
    /// still waiting for its analysis draw exactly the state an empty history
    /// draws, rather than inventing a third one. Every card is sample-gated, so
    /// "no data yet" and "no data" self-suppress identically.
    static let empty = MoodInsights(
        dailyAverages: [],
        latestScore: nil,
        mean: nil,
        avg30: nil,
        slope7: nil,
        slope30: nil,
        slope90: nil,
        avg30PriorPeriod: nil,
        stability: nil,
        tagDeltas: [],
        patterns: [],
        entryCount: 0,
        dayCount: 0
    )
}

/// One local calendar day's mean mood score. The engine's shared reduction.
struct MoodDailyAverage: Equatable, Sendable, Identifiable {
    /// `Calendar.startOfDay` for the local day.
    let day: Date
    /// Mean of the scores logged that day (1.0…5.0).
    let average: Double
    /// Number of entries that contributed to `average`.
    let sampleCount: Int

    var id: Date {
        day
    }
}

/// 0…100 stability score + its band + plain-language sentence.
struct MoodStability: Equatable, Sendable {
    let score: Int
    let stdDev: Double
    let band: Band

    enum Band: String, Equatable, Sendable {
        case verySteady
        case steady
        case variable
        case unsettled
        case veryUnsettled

        /// Pure band mapping for the unit-test seam.
        static func band(forScore score: Int) -> Band {
            switch score {
            case 80...: .verySteady
            case 60 ..< 80: .steady
            case 40 ..< 60: .variable
            case 20 ..< 40: .unsettled
            default: .veryUnsettled
            }
        }

        /// `true` when the band is low enough to warm the gauge marker
        /// (DESIGN-B §3.4 — `statusWarn`, score < 40).
        var isFlagged: Bool {
            self == .unsettled || self == .veryUnsettled
        }
    }
}

/// One tag → avg-mood delta vs the overall baseline.
struct MoodTagDelta: Equatable, Sendable, Identifiable {
    let tag: String
    /// Mean mood of entries carrying this tag.
    let average: Double
    /// `average − overallAverage`.
    let delta: Double
    /// Occurrences (entries carrying the tag).
    let count: Int

    var id: String {
        tag
    }

    var isPositive: Bool {
        delta >= 0
    }
}

/// One gated correlation finding — surfaced as a Pattern card.
struct MoodPattern: Equatable, Sendable, Identifiable {
    /// Stable id (matches the detector, e.g. `best-day`, `weekend`).
    let id: String
    let kind: Kind
    let strength: Strength
    let direction: Direction
    /// Pre-resolved, localized plain-language sentence (de/en via xcstrings).
    let sentence: String
    /// SF Symbol for the leading glyph.
    let icon: String

    enum Strength: Equatable, Sendable {
        case moderate
        case strong
    }

    enum Direction: Equatable, Sendable {
        case positive
        case negative
        case neutral
    }

    /// Category — drives the uppercase label + grouping.
    enum Kind: String, Equatable, Sendable {
        case previousDay
        case weekend
        case bestWeekday
        case tagPositive
        case tagNegative
        case notePresence
        case laggedTag
        case multiEntry
    }
}

// MARK: - Computation

extension MoodInsights {
    /// Builds the full insight set from a raw entry list. Pure + offline.
    ///
    /// - Parameters:
    ///   - entries: the cached `MoodEntry` list (any order).
    ///   - now: the reference "today" (injectable for tests).
    ///   - calendar: local calendar (injectable for tests).
    ///   - enrichment: optional server `/api/mood/analytics` override —
    ///     authoritative slopes + prior-period mean when present; client values
    ///     stand otherwise.
    static func compute(
        entries: [MoodEntry],
        now: Date = .now,
        calendar: Calendar = .current,
        enrichment: MoodAnalyticsEnrichment? = nil
    ) -> MoodInsights {
        guard !entries.isEmpty else { return .empty }

        let daily = makeDailyAverages(entries: entries, calendar: calendar)
        let latest = entries.max(by: { $0.recordedAt < $1.recordedAt })?.score
        let mean = daily.isEmpty ? nil : daily.map(\.average).reduce(0, +) / Double(daily.count)

        let avg30 = windowedMean(daily, days: 30, now: now, calendar: calendar)
        let avg30Prior = windowedMean(
            daily, fromDaysAgo: 60, toDaysAgo: 30, now: now, calendar: calendar
        )

        let clientSlope7 = slope(daily, days: 7, now: now, calendar: calendar)
        let clientSlope30 = slope(daily, days: 30, now: now, calendar: calendar)
        let clientSlope90 = slope(daily, days: 90, now: now, calendar: calendar)

        let stability = makeStability(daily)
        let tagDeltas = makeTagDeltas(entries: entries)
        let patterns = MoodPatternDetector.detect(
            entries: entries, daily: daily, calendar: calendar
        )

        return MoodInsights(
            dailyAverages: daily,
            latestScore: latest,
            mean: mean,
            avg30: avg30,
            // Prefer the authoritative server slopes/prior-period when online.
            slope7: enrichment?.slope7 ?? clientSlope7,
            slope30: enrichment?.slope30 ?? clientSlope30,
            slope90: enrichment?.slope90 ?? clientSlope90,
            avg30PriorPeriod: enrichment?.avg30LastMonth ?? avg30Prior,
            stability: stability,
            tagDeltas: tagDeltas,
            patterns: patterns,
            entryCount: entries.count,
            dayCount: daily.count
        )
    }

    /// Collapse entries to one mean-score-per-local-day, ascending. The spine.
    static func makeDailyAverages(entries: [MoodEntry], calendar: Calendar) -> [MoodDailyAverage] {
        var buckets: [Date: [Int]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.recordedAt)
            buckets[day, default: []].append(entry.score)
        }
        return buckets
            .map { day, scores in
                MoodDailyAverage(
                    day: day,
                    average: Double(scores.reduce(0, +)) / Double(scores.count),
                    sampleCount: scores.count
                )
            }
            .sorted { $0.day < $1.day }
    }

    /// Mean of daily averages within the trailing `days` window from `now`.
    private static func windowedMean(
        _ daily: [MoodDailyAverage],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> Double? {
        windowedMean(daily, fromDaysAgo: days, toDaysAgo: 0, now: now, calendar: calendar)
    }

    /// Mean of daily averages within the half-open window
    /// `[now − fromDaysAgo, now − toDaysAgo)` (older bound inclusive, newer
    /// exclusive). Used for both the trailing-30 average and the prior-period
    /// 30-day mean for the zone-1 delta.
    private static func windowedMean(
        _ daily: [MoodDailyAverage],
        fromDaysAgo: Int,
        toDaysAgo: Int,
        now: Date,
        calendar: Calendar
    ) -> Double? {
        let today = calendar.startOfDay(for: now)
        guard let lowerBound = calendar.date(byAdding: .day, value: -fromDaysAgo, to: today),
              let upperBound = calendar.date(byAdding: .day, value: -toDaysAgo, to: today) else { return nil }
        let slice = daily.filter { $0.day >= lowerBound && $0.day < upperBound }
        guard !slice.isEmpty else { return nil }
        return slice.map(\.average).reduce(0, +) / Double(slice.count)
    }

    /// Least-squares slope (score units/day) of the trailing `days` daily
    /// averages, x = days since the window start. `nil` for < 2 points.
    static func slope(
        _ daily: [MoodDailyAverage],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> Double? {
        let today = calendar.startOfDay(for: now)
        guard let lowerBound = calendar.date(byAdding: .day, value: -days, to: today) else { return nil }
        let slice = daily.filter { $0.day >= lowerBound }
        guard slice.count >= 2 else { return nil }
        let points: [(x: Double, y: Double)] = slice.map { avg in
            let dayOffset = calendar.dateComponents([.day], from: lowerBound, to: avg.day).day ?? 0
            return (Double(dayOffset), avg.average)
        }
        let n = Double(points.count)
        let sumX = points.map(\.x).reduce(0, +)
        let sumY = points.map(\.y).reduce(0, +)
        let sumXY = points.map { $0.x * $0.y }.reduce(0, +)
        let sumXX = points.map { $0.x * $0.x }.reduce(0, +)
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > .ulpOfOne else { return nil }
        return (n * sumXY - sumX * sumY) / denom
    }

    /// Port of MoodLog `computeStability` (L220-259): population std-dev of the
    /// daily averages → `round(clamp((1 − std/2) × 100, 0, 100))`.
    static func makeStability(_ daily: [MoodDailyAverage]) -> MoodStability? {
        guard daily.count >= stabilityMinDays else { return nil }
        let values = daily.map(\.average)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let std = variance.squareRoot()
        let score = Int(max(0, min(100, (1 - std / 2) * 100)).rounded())
        return MoodStability(
            score: score,
            stdDev: std,
            band: MoodStability.Band.band(forScore: score)
        )
    }

    /// Port of MoodLog `computeTagStats` (L174-216) + the tag-correlation gate
    /// (L425-461): per tag → mean mood + delta vs overall baseline, gated to
    /// ≥ 3 occurrences AND |delta| ≥ 0.3, sorted by |delta| desc.
    static func makeTagDeltas(entries: [MoodEntry]) -> [MoodTagDelta] {
        guard !entries.isEmpty else { return [] }
        let overall = Double(entries.map(\.score).reduce(0, +)) / Double(entries.count)
        var buckets: [String: [Int]] = [:]
        for entry in entries {
            for tag in entry.tags where !tag.hasPrefix("note:") {
                buckets[tag, default: []].append(entry.score)
            }
        }
        return buckets
            .compactMap { tag, scores -> MoodTagDelta? in
                guard scores.count >= 3 else { return nil }
                let avg = Double(scores.reduce(0, +)) / Double(scores.count)
                let delta = avg - overall
                guard abs(delta) >= 0.3 else { return nil }
                return MoodTagDelta(tag: tag, average: avg, delta: delta, count: scores.count)
            }
            .sorted { lhs, rhs in
                if abs(lhs.delta) != abs(rhs.delta) { return abs(lhs.delta) > abs(rhs.delta) }
                // 09-04 — the tag name is the deterministic final key. `buckets`
                // is a `Dictionary` and `sorted` is not stable, so two tags with
                // an equal |delta| AND an equal count changed places between
                // evaluations of the same history.
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag < rhs.tag
            }
    }
}

/// Authoritative `/api/mood/analytics` override fields the engine prefers when
/// online. Decoded from the server `summary` block (`R-Mood-1` §B). All
/// optional — a missing field falls back to the client computation.
struct MoodAnalyticsEnrichment: Decodable, Equatable, Hashable, Sendable {
    let slope7: Double?
    let slope30: Double?
    let slope90: Double?
    let avg30LastMonth: Double?
    let avg30LastYear: Double?

    /// Decodes the `{ summary: { … } }` envelope the analytics route returns.
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let summary = try root.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
        slope7 = try summary.decodeIfPresent(Double.self, forKey: .slope7)
        slope30 = try summary.decodeIfPresent(Double.self, forKey: .slope30)
        slope90 = try summary.decodeIfPresent(Double.self, forKey: .slope90)
        avg30LastMonth = try summary.decodeIfPresent(Double.self, forKey: .avg30LastMonth)
        avg30LastYear = try summary.decodeIfPresent(Double.self, forKey: .avg30LastYear)
    }

    /// Memberwise init for tests / direct construction.
    init(
        slope7: Double?,
        slope30: Double?,
        slope90: Double?,
        avg30LastMonth: Double?,
        avg30LastYear: Double?
    ) {
        self.slope7 = slope7
        self.slope30 = slope30
        self.slope90 = slope90
        self.avg30LastMonth = avg30LastMonth
        self.avg30LastYear = avg30LastYear
    }

    private enum RootKeys: String, CodingKey { case summary }
    private enum SummaryKeys: String, CodingKey {
        case slope7, slope30, slope90, avg30LastMonth, avg30LastYear
    }
}
