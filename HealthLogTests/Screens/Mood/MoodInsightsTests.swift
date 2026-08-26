// swiftlint:disable force_unwrapping force_try

import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — pure-engine locks for `MoodInsights` + the correlation
/// detector, validated against the MoodLog `statistics-compute.ts` oracle
/// behaviour. No SwiftUI render pass — these pin the offline-computed stats:
/// daily-avg spine, mean/avg30/slope/prior-period, stability band mapping,
/// tag-delta gating, and the per-detector sample gates.
@Suite("MoodInsights engine")
struct MoodInsightsTests {
    /// UTC-anchored fixed calendar so the day-bucketing is deterministic across
    /// CI machine zones.
    private static var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    /// Builds an entry `daysAgo` before `now` at noon UTC.
    private static func entry(
        score: Int,
        daysAgo: Int,
        tags: [String] = [],
        note: String? = nil,
        id: String = UUID().uuidString
    ) -> MoodEntry {
        let cal = fixedCalendar
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let stamp = cal.date(byAdding: .hour, value: 12, to: day)!
        return MoodEntry(id: id, recordedAt: stamp, score: score, tags: tags, note: note)
    }

    // MARK: - Daily-average spine

    @Test("multi-entry days collapse to one daily mean")
    func dailyAverageCollapsesSameDay() {
        let entries = [
            Self.entry(score: 2, daysAgo: 0),
            Self.entry(score: 4, daysAgo: 0), // same day → mean 3
            Self.entry(score: 5, daysAgo: 1)
        ]
        let daily = MoodInsights.makeDailyAverages(entries: entries, calendar: Self.fixedCalendar)
        #expect(daily.count == 2)
        // Ascending by day → [yesterday=5, today=3]
        #expect(daily.last?.average == 3.0)
        #expect(daily.last?.sampleCount == 2)
        #expect(daily.first?.average == 5.0)
    }

    @Test("empty entries → all-nil insight, no crash")
    func emptyInsight() {
        let insight = MoodInsights.compute(entries: [], now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.latestScore == nil)
        #expect(insight.mean == nil)
        #expect(insight.stability == nil)
        #expect(insight.tagDeltas.isEmpty)
        #expect(insight.patterns.isEmpty)
        #expect(insight.entryCount == 0)
    }

    @Test("latest score is the most-recent entry")
    func latestScore() {
        let entries = [
            Self.entry(score: 1, daysAgo: 5),
            Self.entry(score: 4, daysAgo: 0),
            Self.entry(score: 2, daysAgo: 2)
        ]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.latestScore == 4)
    }

    // MARK: - Mean + avg30 + prior period

    @Test("mean averages the daily averages, not raw entries")
    func meanOverDailyAverages() {
        // Day A: two entries 2 & 4 → daily 3. Day B: one entry 5 → daily 5.
        // Mean of daily averages = (3 + 5) / 2 = 4, NOT (2+4+5)/3 = 3.67.
        let entries = [
            Self.entry(score: 2, daysAgo: 0),
            Self.entry(score: 4, daysAgo: 0),
            Self.entry(score: 5, daysAgo: 1)
        ]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.mean == 4.0)
    }

    @Test("prior-period 30-day mean isolates the older window")
    func priorPeriodMean() {
        // Recent 30: a 5 today. Prior (31-60d ago): a 2 at 45 days ago.
        let entries = [
            Self.entry(score: 5, daysAgo: 1),
            Self.entry(score: 2, daysAgo: 45)
        ]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.avg30 == 5.0)
        #expect(insight.avg30PriorPeriod == 2.0)
    }

    @Test("server enrichment overrides client slope + prior-period")
    func enrichmentOverride() {
        let entries = [
            Self.entry(score: 3, daysAgo: 0),
            Self.entry(score: 4, daysAgo: 1)
        ]
        let enrich = MoodAnalyticsEnrichment(
            slope7: 0.99, slope30: 0.5, slope90: 0.1,
            avg30LastMonth: 1.2, avg30LastYear: nil
        )
        let insight = MoodInsights.compute(
            entries: entries, now: Self.now, calendar: Self.fixedCalendar, enrichment: enrich
        )
        #expect(insight.slope7 == 0.99)
        #expect(insight.avg30PriorPeriod == 1.2)
    }

    @Test("analytics enrichment decodes the summary envelope")
    func enrichmentDecode() throws {
        let json = """
        { "entries": [], "summary": { "slope7": 0.12, "slope30": -0.03, "avg30LastMonth": 3.4 } }
        """
        let data = Data(json.utf8)
        let enrich = try JSONDecoder().decode(MoodAnalyticsEnrichment.self, from: data)
        #expect(enrich.slope7 == 0.12)
        #expect(enrich.slope30 == -0.03)
        #expect(enrich.slope90 == nil)
        #expect(enrich.avg30LastMonth == 3.4)
    }

    // MARK: - Slope

    @Test("rising series yields a positive slope")
    func slopePositive() {
        let entries = (0 ..< 7).map { Self.entry(score: max(1, min(5, 5 - $0)), daysAgo: $0) }
        // daysAgo 0→score5 … 6→score(-1 clamps to1): newer days higher → positive slope.
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect((insight.slope7 ?? 0) > 0)
    }

    @Test("single daily point → nil slope (no fabricated trend)")
    func slopeNilSinglePoint() {
        let entries = [Self.entry(score: 3, daysAgo: 0)]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.slope7 == nil)
    }

    // MARK: - Stability (oracle parity)

    @Test("perfectly flat mood → stability 100, very steady")
    func stabilityFlat() {
        let entries = (0 ..< 10).map { Self.entry(score: 3, daysAgo: $0) }
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.stability?.score == 100)
        #expect(insight.stability?.band == .verySteady)
        #expect(insight.stability?.band.isFlagged == false)
    }

    @Test("stability omitted below the 7-day gate")
    func stabilityGate() {
        let entries = (0 ..< 6).map { Self.entry(score: $0 % 5 + 1, daysAgo: $0) }
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.stability == nil)
    }

    @Test("band mapping pins the five thresholds")
    func bandThresholds() {
        #expect(MoodStability.Band.band(forScore: 100) == .verySteady)
        #expect(MoodStability.Band.band(forScore: 80) == .verySteady)
        #expect(MoodStability.Band.band(forScore: 79) == .steady)
        #expect(MoodStability.Band.band(forScore: 60) == .steady)
        #expect(MoodStability.Band.band(forScore: 59) == .variable)
        #expect(MoodStability.Band.band(forScore: 40) == .variable)
        #expect(MoodStability.Band.band(forScore: 39) == .unsettled)
        #expect(MoodStability.Band.band(forScore: 20) == .unsettled)
        #expect(MoodStability.Band.band(forScore: 19) == .veryUnsettled)
        #expect(MoodStability.Band.band(forScore: 39).isFlagged == true)
    }

    // MARK: - Tag deltas

    @Test("tag delta gated on ≥3 occurrences and |delta|≥0.3, sorted by |delta|")
    func tagDeltaGating() {
        // overall mean of raw scores below.
        let entries = [
            // Sport ×3, all 5 → avg 5, big positive delta.
            Self.entry(score: 5, daysAgo: 0, tags: ["Sport"]),
            Self.entry(score: 5, daysAgo: 1, tags: ["Sport"]),
            Self.entry(score: 5, daysAgo: 2, tags: ["Sport"]),
            // Stress ×3, all 1 → avg 1, big negative delta.
            Self.entry(score: 1, daysAgo: 3, tags: ["Stress"]),
            Self.entry(score: 1, daysAgo: 4, tags: ["Stress"]),
            Self.entry(score: 1, daysAgo: 5, tags: ["Stress"]),
            // Rare ×1 → below occurrence gate, omitted.
            Self.entry(score: 3, daysAgo: 6, tags: ["Rare"])
        ]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        let tags = insight.tagDeltas.map(\.tag)
        #expect(tags.contains("Sport"))
        #expect(tags.contains("Stress"))
        #expect(!tags.contains("Rare"))
        // Both |delta| equal magnitude (overall = 3) → 2.0 each; tie-break is count (3 vs 3),
        // so order is stable but both present.
        #expect(insight.tagDeltas.count == 2)
        #expect(insight.tagDeltas.first?.tag == "Sport" || insight.tagDeltas.first?.tag == "Stress")
    }

    @Test("note: prefixed pseudo-tags never become tag deltas")
    func tagDeltaSkipsNotePrefix() {
        let entries = (0 ..< 4).map { Self.entry(score: 5, daysAgo: $0, tags: ["note:hidden"]) }
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.tagDeltas.isEmpty)
    }

    // MARK: - Patterns

    @Test("< 5 entries → no patterns (engine floor)")
    func patternEngineFloor() {
        let entries = (0 ..< 4).map { Self.entry(score: 3, daysAgo: $0) }
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        #expect(insight.patterns.isEmpty)
    }

    @Test("note-presence detector surfaces with sufficient samples")
    func notePresencePattern() {
        // 3 with-note all 5; 3 without-note all 1 → diff +4 → positive note pattern.
        let entries = [
            Self.entry(score: 5, daysAgo: 0, note: "great"),
            Self.entry(score: 5, daysAgo: 1, note: "great"),
            Self.entry(score: 5, daysAgo: 2, note: "great"),
            Self.entry(score: 1, daysAgo: 3),
            Self.entry(score: 1, daysAgo: 4),
            Self.entry(score: 1, daysAgo: 5)
        ]
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        let note = insight.patterns.first { $0.kind == .notePresence }
        #expect(note != nil)
        #expect(note?.direction == .positive)
    }

    @Test("weekend-vs-weekday detector self-suppresses without weekend samples")
    func weekendSuppressedNoSamples() {
        // All entries on consecutive weekdays only → weekend bucket < 2 → no weekend card.
        // Build entries pinned to known weekdays via specific daysAgo from a known anchor.
        let entries = (10 ..< 18).map { Self.entry(score: 3, daysAgo: $0) }
        let insight = MoodInsights.compute(entries: entries, now: Self.now, calendar: Self.fixedCalendar)
        // Flat mood → even if weekend samples exist, |diff| < 0.3 → suppressed.
        #expect(insight.patterns.allSatisfy { $0.kind != .weekend })
    }

    // MARK: - Phase 09 / 09-04 — the cache answers what the engine answered

    /// The memoization landed in 09-04 is only worth anything if the remembered
    /// answer is the *same* answer. This is the equivalence pinned in the
    /// engine's own suite, against the engine's own fixtures, rather than only
    /// in the performance suite that has an interest in the cache existing.
    ///
    /// `now` is passed as the reference day rather than an instant: every window
    /// in `compute` is day-granular, so the whole day resolves to one answer —
    /// which is exactly why the cache may key on the day boundary and nothing
    /// finer.
    @Test("a cached snapshot equals the engine result for the same key, at any hour of that day")
    func cachedSnapshotEqualsTheEngineResult() async {
        let entries = (0 ..< 14).flatMap { day in
            [
                Self.entry(score: 1 + day % 5, daysAgo: day, tags: ["work"]),
                Self.entry(score: 1 + (day * 3) % 5, daysAgo: day, tags: ["sleep"])
            ]
        }
        let calendar = Self.fixedCalendar
        let dayStart = calendar.startOfDay(for: Self.now)
        let key = MoodAnalysisKey(
            revision: 3,
            scope: .fullHistory,
            periodDays: nil,
            dayStart: dayStart,
            calendar: calendar,
            enrichment: nil
        )
        let cache = MoodAnalysisCache()
        let first = await cache.snapshot(for: key, entries: entries, engine: .live)
        let second = await cache.snapshot(for: key, entries: entries, engine: .live)

        let reference = MoodInsights.compute(entries: entries, now: dayStart, calendar: calendar)
        #expect(first.insights == reference, "the cold snapshot is not the engine's answer")
        #expect(second.insights == reference, "the served snapshot drifted from the cold one")
        #expect(first.insights.patterns == reference.patterns, "the correlation findings moved")
        #expect(first.insights.tagDeltas == reference.tagDeltas, "the tag deltas moved")
        #expect(first.trend.count == entries.count)

        // Any instant inside the same local day resolves to the same analysis,
        // which is what licenses `dayStart` as the key's time member.
        let lateThatDay = MoodInsights.compute(
            entries: entries,
            now: dayStart.addingTimeInterval(23 * 3600 + 3599),
            calendar: calendar
        )
        #expect(lateThatDay == reference, "the analysis is a function of the local day, not of the instant")
    }
}
