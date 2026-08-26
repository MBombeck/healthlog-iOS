import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **audit-v0162 M-2 / M-3 / M-4 regression coverage — cache-invalidation gaps.**
///
/// - **M-2:** mood writes never invalidated the `.moodEntries` slice (the doc
///   claimed they did; the `moodEntryChange` matrix arm was dead AND omitted the
///   365-day window the store reads).
/// - **M-3:** `.measurementsRecentKind` (per-kind chart-detail page) was never
///   invalidated by any write.
/// - **M-4:** `.measurementAvailability` was never invalidated by any write.
@Suite("Cache-invalidation mediums (M-2 / M-3 / M-4)")
struct CacheInvalidationMediumsTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(true)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    // MARK: - M-2 — mood write invalidates the served 365-day slice

    @Test("M-2: MoodStore observes days:365 — the moodEntryChange arm now includes it")
    func moodEntryChangeArmCoversStoreWindow() {
        let keys = MutationKind.moodEntryChange.affectedKeys
        #expect(keys.contains(.moodEntries(days: 365)), "the store reads days:365 — the arm must drop it")
    }

    @Test("M-2: a committed mood log drops the cached .moodEntries(days:365) slice")
    func moodLogInvalidatesEntriesCache() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        // Pre-seed the slice the store reads.
        let seed = [MoodEntry(
            id: "old",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            score: 3,
            tags: [],
            tagKeys: [],
            note: nil
        )]
        try await cache.write(.moodEntries(days: 365), payload: JSONEncoder.hlDefault.encode(seed))
        #expect(await coordinator.peek(.moodEntries(days: 365), as: [MoodEntry].self) != nil)

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox, swr: coordinator)
        await api.setHandler { _ in
            MoodEntry(id: "srv", recordedAt: .now, score: 4, tags: [], tagKeys: [], note: nil)
        }

        _ = try await repo.log(score: 4, tags: [], tagKeys: [], note: nil)

        #expect(
            await coordinator.peek(.moodEntries(days: 365), as: [MoodEntry].self) == nil,
            "M-2: the mood write must invalidate the served slice"
        )
    }

    // MARK: - M-3 / M-4 — measurement write invalidates kind-page + availability

    @Test("M-3/M-4: a measurement create drops the kind-scoped chart page + availability slice")
    func measurementCreateInvalidatesKindPageAndAvailability() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        // Seed the per-kind chart-detail page (M-3) + the availability slice (M-4).
        try await cache.write(
            .measurementsRecentKind(type: "WEIGHT", limit: 400),
            payload: JSONEncoder.hlDefault.encode([HealthLog.Measurement]())
        )
        try await cache.write(
            .measurementAvailability,
            payload: JSONEncoder.hlDefault.encode(["WEIGHT"])
        )
        #expect(await coordinator.peek(.measurementsRecentKind(type: "WEIGHT", limit: 400), as: [HealthLog.Measurement].self) != nil)
        #expect(await coordinator.peek(.measurementAvailability, as: [String].self) != nil)

        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox, swr: coordinator)
        await api.setHandler { _ in
            MeasurementWireDTO(id: "srv-1", type: .weight, value: 72.5, measuredAt: .now)
        }

        _ = try await repo.create(
            HealthLog.Measurement(id: "local-1", kind: .weight, recordedAt: .now, value: .scalar(72.5))
        )

        #expect(
            await coordinator.peek(.measurementsRecentKind(type: "WEIGHT", limit: 400), as: [HealthLog.Measurement].self) == nil,
            "M-3: the write must drop the kind-scoped chart page"
        )
        #expect(
            await coordinator.peek(.measurementAvailability, as: [String].self) == nil,
            "M-4: the write must drop the availability slice"
        )
    }
}
