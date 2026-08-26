import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// **v0.12 W8-4 / W8-6** — locks the cache-sweep + off-main-downsample work.
///
/// W8-4: `SWRCoordinator.sweepOlderThan` (the passthrough the BGTask cache-sweep
/// hook calls) must drop rows older than the window and keep fresh rows.
/// W8-6: moving `SeriesDownsampler` off the main actor must produce byte-for-byte
/// identical output (it's a pure function over value types).
@Suite("W8 — cache sweep + off-main downsample")
struct W8CacheSweepTests {
    private struct Payload: Codable, Equatable {
        let id: String
    }

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

    @Test("SWRCoordinator.sweepOlderThan drops stale rows, keeps fresh ones")
    func coordinatorSweepDropsStale() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = try JSONEncoder.hlDefault.encode(Payload(id: "x"))

        // One row 40 days old (stale vs a 30-day window), one fresh.
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: payload, at: now.addingTimeInterval(-40 * 24 * 60 * 60))
        try await cache.write(.healthScore, payload: payload, at: now)

        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let dropped = await coordinator.sweepOlderThan(30 * 24 * 60 * 60, now: now)

        #expect(dropped == 1)
        // The fresh row survives; the stale one is gone.
        #expect(await cache.read(.healthScore, as: Payload.self) != nil)
        #expect(await cache.read(.dashboardSummary(day: "2026-06-06"), as: Payload.self) == nil)
    }

    @Test("SWRCoordinator.sweepOlderThan is a no-op when nothing is stale")
    func coordinatorSweepNoOp() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = try JSONEncoder.hlDefault.encode(Payload(id: "x"))
        try await cache.write(.dashboardSummary(day: "2026-06-06"), payload: payload, at: now)

        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())
        let dropped = await coordinator.sweepOlderThan(30 * 24 * 60 * 60, now: now)
        #expect(dropped == 0)
    }

    // MARK: - AUD-8 H-1 — row-count cap + foreground maintenance sweep

    @Test("SWRCoordinator.sweepKeepingNewest enforces the row cap (AUD-8 H-1)")
    func coordinatorCapEvictsOldest() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = try JSONEncoder.hlDefault.encode(Payload(id: "x"))
        for i in 0 ..< 10 {
            try await cache.write(
                .dashboardSummary(day: "row-\(String(format: "%04d", i))"),
                payload: payload,
                at: now.addingTimeInterval(-Double(i) * 24 * 60 * 60)
            )
        }
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())

        let evicted = await coordinator.sweepKeepingNewest(maxRows: 3)
        #expect(evicted >= 7)
        #expect(try await cache.rowCount() <= 3)
        // newest survives, oldest gone
        #expect(await cache.read(.dashboardSummary(day: "row-0000"), as: Payload.self) != nil)
        #expect(await cache.read(.dashboardSummary(day: "row-0009"), as: Payload.self) == nil)
    }

    @Test("foregroundMaintenanceSweep ages AND caps in one pass (AUD-8 H-1)")
    func coordinatorForegroundSweepAgesAndCaps() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = try JSONEncoder.hlDefault.encode(Payload(id: "x"))
        // 12 rows, each i days old; rows 0..11 days old.
        for i in 0 ..< 12 {
            try await cache.write(
                .dashboardSummary(day: "row-\(String(format: "%04d", i))"),
                payload: payload,
                at: now.addingTimeInterval(-Double(i) * 24 * 60 * 60)
            )
        }
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach())

        // Age-sweep drops rows older than 6 days (rows 7..11 → 5 rows); then the
        // cap (maxRows: 3) trims the remaining 7 down to 3.
        let dropped = await coordinator.foregroundMaintenanceSweep(
            maxAge: 6 * 24 * 60 * 60,
            maxRows: 3,
            now: now
        )
        #expect(dropped >= 9)
        #expect(try await cache.rowCount() <= 3)
    }

    @Test("Off-main downsample matches on-main output exactly (W8-6)")
    func offMainDownsampleIsIdentical() async {
        // ~1500 points across 365 days — wide enough to trip the downsampler.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let points: [SeriesPoint] = (0 ..< 1500).map { i in
            SeriesPoint(
                id: "p-\(i)",
                at: base.addingTimeInterval(Double(i) * 6 * 60 * 60),
                value: Double(i % 97),
                secondary: nil
            )
        }

        let onMain = SeriesDownsampler.downsampleIfNeeded(points, rangeDays: 365)
        let offMain = await Task.detached(priority: .userInitiated) {
            SeriesDownsampler.downsampleIfNeeded(points, rangeDays: 365)
        }.value

        #expect(onMain.count == offMain.count)
        #expect(onMain.map(\.value) == offMain.map(\.value))
        #expect(onMain.map(\.at) == offMain.map(\.at))
    }
}
