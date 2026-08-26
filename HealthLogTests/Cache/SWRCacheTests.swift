import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// Locks the persistent cache round-trip (write → read → invalidate)
/// against the SwiftData @ModelActor implementation. Mirrors
/// `OutboxPersistenceTests` shape, using the in-memory container so the
/// test suite runs without disk I/O.
@Suite("SWRCache round-trip")
struct SWRCacheTests {
    private struct TestPayload: Codable, Equatable {
        let id: String
        let value: Int
    }

    @Test("Write then read returns the same value with a recent timestamp")
    func writeThenRead() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        let payload = TestPayload(id: "abc", value: 42)
        let data = try JSONEncoder.hlDefault.encode(payload)
        try await cache.write(.userProfile, payload: data)

        let result: Cached<TestPayload>? = await cache.read(.userProfile, as: TestPayload.self)
        let cached = try #require(result)
        #expect(cached.value == payload)
        // Wall-clock within last few seconds.
        #expect(abs(cached.updatedAt.timeIntervalSinceNow) < 5)
    }

    @Test("Read on a missing key returns nil (cache-miss)")
    func readMissing() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        let result: Cached<TestPayload>? = await cache.read(.userProfile, as: TestPayload.self)
        #expect(result == nil)
    }

    @Test("Write twice updates same row (no duplicate keyHash)")
    func updateInPlace() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: JSONEncoder.hlDefault.encode(TestPayload(id: "1", value: 1)))
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: JSONEncoder.hlDefault.encode(TestPayload(id: "1", value: 2)))
        let cached: Cached<TestPayload>? = await cache.read(.dashboardSummary(day: "2026-06-06"), as: TestPayload.self)
        #expect(cached?.value.value == 2)
    }

    @Test("Invalidate drops a single key")
    func invalidate() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        let data = try JSONEncoder.hlDefault.encode(TestPayload(id: "x", value: 1))
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: data)
        try await cache.write(.healthScore, payload: data)
        try await cache.invalidate([.dashboardSummary(day: "2026-06-06")])
        let dash: Cached<TestPayload>? = await cache.read(.dashboardSummary(day: "2026-06-06"), as: TestPayload.self)
        let hs: Cached<TestPayload>? = await cache.read(.healthScore, as: TestPayload.self)
        #expect(dash == nil)
        #expect(hs != nil)
    }

    @Test("invalidateAll wipes every row (logout cascade)")
    func invalidateAll() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        let data = try JSONEncoder.hlDefault.encode(TestPayload(id: "x", value: 1))
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: data)
        try await cache.write(.healthScore, payload: data)
        try await cache.write(.medicationsList, payload: data)
        try await cache.invalidateAll()
        let a: Cached<TestPayload>? = await cache.read(.dashboardSummary(day: "2026-06-06"), as: TestPayload.self)
        let b: Cached<TestPayload>? = await cache.read(.healthScore, as: TestPayload.self)
        let c: Cached<TestPayload>? = await cache.read(.medicationsList, as: TestPayload.self)
        #expect(a == nil)
        #expect(b == nil)
        #expect(c == nil)
    }

    // MARK: - AUD-8 H-1 — row-count cap + batch sweep

    /// Writes `count` distinct day-keyed rows, each stamped `i` days ago so the
    /// oldest are deterministically lowest `updatedAt`.
    private func seedDayRows(_ cache: SWRCache, count: Int, now: Date = .now) async throws {
        let data = try JSONEncoder.hlDefault.encode(TestPayload(id: "x", value: 1))
        for i in 0 ..< count {
            let day = "row-\(String(format: "%04d", i))"
            let stamp = now.addingTimeInterval(-Double(i) * 24 * 60 * 60)
            try await cache.write(.dashboardSummary(day: day), payload: data, at: stamp)
        }
    }

    @Test("sweepKeepingNewest evicts the oldest rows beyond the cap (AUD-8 H-1)")
    func capEvictsOldest() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        try await seedDayRows(cache, count: 10)
        #expect(try await cache.rowCount() == 10)

        let evicted = try await cache.sweepKeepingNewest(maxRows: 4)
        #expect(evicted >= 6) // at least the 6 over-cap rows dropped
        let remaining = try await cache.rowCount()
        #expect(remaining <= 4)

        // The NEWEST row (i == 0, stamped now) must survive; an old one must not.
        let newest: Cached<TestPayload>? = await cache.read(.dashboardSummary(day: "row-0000"), as: TestPayload.self)
        let oldest: Cached<TestPayload>? = await cache.read(.dashboardSummary(day: "row-0009"), as: TestPayload.self)
        #expect(newest != nil)
        #expect(oldest == nil)
    }

    @Test("sweepKeepingNewest is a no-op at/below the cap (AUD-8 H-1)")
    func capNoOpWhenUnderLimit() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        try await seedDayRows(cache, count: 3)
        let evicted = try await cache.sweepKeepingNewest(maxRows: 10)
        #expect(evicted == 0)
        #expect(try await cache.rowCount() == 3)
    }

    @Test("sweepOlderThan batch-drops only the aged rows (AUD-8 L-4)")
    func ageSweepBatchDeletes() async throws {
        let container = try SWRCache.makeInMemory()
        let cache = SWRCache(modelContainer: container)
        let now = Date.now
        // 5 rows: i days old → rows 0..4 days old.
        try await seedDayRows(cache, count: 5, now: now)
        // Drop everything STRICTLY older than 2 days → rows at 3 and 4 days old
        // go (the 2-days-old row sits exactly on the boundary and survives).
        let dropped = try await cache.sweepOlderThan(2 * 24 * 60 * 60, now: now)
        #expect(dropped == 2)
        #expect(try await cache.rowCount() == 3)
    }

    @Test("Cached.isStale honours per-key staleAfter")
    func isStale() {
        let pastWriteTime = Date().addingTimeInterval(-200) // 200s ago
        let cached = Cached(value: 1, updatedAt: pastWriteTime)
        // .healthScore staleAfter is 60s — at 200s ago it is stale.
        #expect(cached.isStale(per: .healthScore))
        // .userProfile is 5*60 — at 200s it is still fresh.
        #expect(!cached.isStale(per: .userProfile))
    }
}

@Suite("CacheKey persistent hashing")
struct CacheKeyHashingTests {
    @Test("Same key value yields the same persistentHash across constructions")
    func stableHash() {
        let a = CacheKey.measurementSeries(kind: .weight, days: 30).persistentHash
        let b = CacheKey.measurementSeries(kind: .weight, days: 30).persistentHash
        #expect(a == b)
    }

    @Test("Different parameters yield different hashes")
    func paramDifferentiated() {
        let a = CacheKey.measurementSeries(kind: .weight, days: 30).persistentHash
        let b = CacheKey.measurementSeries(kind: .weight, days: 90).persistentHash
        let c = CacheKey.measurementSeries(kind: .pulse, days: 30).persistentHash
        #expect(a != b)
        #expect(a != c)
        #expect(b != c)
    }

    @Test("Canonical strings are human-readable for debug")
    func canonical() {
        #expect(CacheKey.dashboardSummary(day: "2026-06-06").canonicalString == "dashboardSummary:2026-06-06")
        #expect(CacheKey.measurementSeries(kind: .weight, days: 30).canonicalString == "measurementSeries:weight:30")
        #expect(CacheKey.metricInsights(kind: .bloodPressure, locale: "de").canonicalString == "metricInsights:bloodPressure:de")
    }

    @Test("staleAfter is non-negative for every case")
    func staleAfterPositive() {
        let cases: [CacheKey] = [
            .dashboardSummary(day: "2026-06-06"), .healthScore, .insightsComprehensive,
            .insightsCards, .correlations, .measurementsRecent(limit: 50),
            .measurementSeries(kind: .weight, days: 30), .medicationsList,
            .medicationsTodayIntakes(day: "2026-06-06"), .medicationsCompliance(days: 84),
            .moodEntries(days: 30), .userProfile,
            .hkSyncConfig, .notificationsPreferences,
            .metricInsights(kind: .pulse, locale: "de"), .dailyBriefing(day: "2026-06-06")
        ]
        for key in cases {
            #expect(key.staleAfter >= 0, "staleAfter must be >= 0 for \(key)")
        }
    }
}

@Suite("CacheInvalidator mutation matrix")
struct CacheInvalidatorMatrixTests {
    @Test("Every MutationKind maps to at least one key")
    func nonEmpty() {
        let cases: [MutationKind] = [
            .measurementChange(kind: .weight),
            .moodEntryChange,
            .medicationChange,
            .medicationIntakeChange,
            .insightsFeedback,
            .settingsChange
        ]
        for mutation in cases {
            #expect(!mutation.affectedKeys.isEmpty, "\(mutation) has no affected keys")
        }
    }

    @Test("measurementChange always invalidates dashboardSummary + healthScore")
    func measurementChangeFanOut() {
        let keys = MutationKind.measurementChange(kind: .weight).affectedKeys
        #expect(keys.contains(.dashboardSummary(day: MedicationDayKey.string(timeZone: .current))))
        #expect(keys.contains(.healthScore))
        #expect(keys.contains(.measurementsRecent(limit: 50)))
    }

    @Test("medicationIntakeChange invalidates today-intakes + healthScore")
    func medicationIntakeFanOut() {
        let keys = MutationKind.medicationIntakeChange.affectedKeys
        // v0.14.1 INV-med-cadence-phantom (BUG 2) — today-intakes is now
        // day-anchored (current device-tz day in the static matrix fallback).
        #expect(keys.contains(.medicationsTodayIntakes(day: MedicationDayKey.string(timeZone: .current))))
        #expect(keys.contains(.healthScore))
    }
}
