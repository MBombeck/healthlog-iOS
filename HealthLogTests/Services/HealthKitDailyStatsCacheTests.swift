import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// Phase 07 / Plan 07-04 — the daily-stat cache is owner-partitioned.
///
/// **Restatement.** Every read/write/plan test below used to be keyed by
/// `(hkIdentifier, dayKey)` alone. That key was installation-global, which is
/// the defect: account B read the `lastPostedValue` account A had written, took
/// the day for converged, and never posted B's own total — while a sweep under
/// B could overwrite A's row. The read/write/plan *semantics* are unchanged and
/// still asserted; the key gained the account, and two new sections pin what
/// the partition must refuse.
@Suite("HealthKitDailyStatsCache — owner-partitioned read/write/plan semantics")
struct HealthKitDailyStatsCacheTests {
    // MARK: - Helpers

    private static let ownerA = "account-a"
    private static let ownerB = "account-b"

    private func makeCache() throws -> HealthKitDailyStatsCache {
        let container = try HealthKitDailyStatsCache.makeInMemory()
        return HealthKitDailyStatsCache(modelContainer: container)
    }

    private func sampleRow(
        identifier: String = "HKQuantityTypeIdentifierStepCount",
        dayKey: String = "2026-05-16",
        value: Double = 8345
    ) -> HealthKitDailyStatRow {
        HealthKitDailyStatRow(
            hkIdentifier: identifier,
            dayStart: Date(timeIntervalSince1970: 1_716_000_000),
            dayKey: dayKey,
            value: value,
            unit: "steps"
        )
    }

    // MARK: - Read / write

    @Test("Empty cache returns nil for read")
    func emptyRead() async throws {
        let cache = try makeCache()
        let entry = await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        )
        #expect(entry == nil)
    }

    @Test("Write then read round-trips value")
    func writeReadRoundtrip() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345,
            serverMeasurementId: "meas_abc123"
        )
        let entry = try #require(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ))
        #expect(entry.lastPostedValue == 8345)
        #expect(entry.serverMeasurementId == "meas_abc123")
        #expect(entry.dayKey == "2026-05-16")
        #expect(entry.ownerUserID == Self.ownerA)
    }

    @Test("Write twice on same key — upserts (no duplicate row)")
    func writeUpserts() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 5000
        )
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345,
            serverMeasurementId: "meas_abc123"
        )
        #expect(try await cache.count(ownerUserID: Self.ownerA) == 1, "compoundKey unique-Index keeps this at 1 row")
        let entry = try #require(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ))
        #expect(entry.lastPostedValue == 8345)
        #expect(entry.serverMeasurementId == "meas_abc123")
    }

    @Test("Write with nil serverId preserves existing serverId")
    func writeNilIdPreservesExisting() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 5000,
            serverMeasurementId: "meas_abc123"
        )
        // Second write without server-id — should NOT clobber the anchored id.
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345,
            serverMeasurementId: nil
        )
        let entry = try #require(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ))
        #expect(entry.lastPostedValue == 8345)
        #expect(entry.serverMeasurementId == "meas_abc123")
    }

    @Test("A write without a named account is refused")
    func unownedWriteIsRefused() async throws {
        let cache = try makeCache()
        for owner in ["", "   "] {
            await #expect(throws: HealthKitDailyStatsCacheError.unownedWriteRefused) {
                try await cache.write(
                    ownerUserID: owner,
                    hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                    dayKey: "2026-05-16",
                    lastPostedValue: 8345
                )
            }
        }
        #expect(try await cache.totalRowCount() == 0)
    }

    // MARK: - plan(for:) — two-way decision

    @Test("plan returns .post when this account has no cache entry")
    func planEmpty() async throws {
        let cache = try makeCache()
        let row = sampleRow(value: 8345)
        let action = await cache.plan(ownerUserID: Self.ownerA, for: row)
        #expect(action == .post(row: row))
    }

    @Test("plan returns .skip when cached value matches new total")
    func planSkipSameValue() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345,
            serverMeasurementId: "meas_abc123"
        )
        let row = sampleRow(value: 8345)
        let action = await cache.plan(ownerUserID: Self.ownerA, for: row)
        if case let .skip(reason) = action {
            #expect(reason == "lastPostedValueMatches")
        } else {
            Issue.record("Expected .skip, got \(action)")
        }
    }

    /// **Restated.** Two tests used to live here: `.patch` when a server id was
    /// cached, `.repost` when it was not. The server id was never obtained by
    /// the production path, so the `.patch` arm was unreachable and the two
    /// cases were one case. A divergent total is now a single `.upsert` of the
    /// stable `stats:` identity, with or without a cached server id.
    @Test("plan returns .upsert on divergence, with or without a cached server id")
    func planUpsertsOnDivergence() async throws {
        for serverID in ["meas_abc123", nil] {
            let cache = try makeCache()
            try await cache.write(
                ownerUserID: Self.ownerA,
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-05-16",
                lastPostedValue: 5000,
                serverMeasurementId: serverID
            )
            let row = sampleRow(value: 8345) // late-Watch-Sync: total grew
            let action = await cache.plan(ownerUserID: Self.ownerA, for: row)
            #expect(action == .upsert(row: row))
        }
    }

    // MARK: - Owner isolation

    @Test("Account B cannot read Account A's day")
    func readsScopedPerOwner() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345
        )
        #expect(await cache.read(
            ownerUserID: Self.ownerB,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ) == nil)
    }

    @Test("Account B's plan is .post for a day Account A already posted")
    func planIsPostForTheOtherAccount() async throws {
        let cache = try makeCache()
        let row = sampleRow(value: 8345)
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: row.hkIdentifier,
            dayKey: row.dayKey,
            lastPostedValue: row.value
        )
        #expect(await cache.plan(ownerUserID: Self.ownerA, for: row) == .skip(reason: "lastPostedValueMatches"))
        #expect(await cache.plan(ownerUserID: Self.ownerB, for: row) == .post(row: row))
    }

    @Test("Account B's write does not disturb Account A's row")
    func writesScopedPerOwner() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345
        )
        try await cache.write(
            ownerUserID: Self.ownerB,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 12
        )
        let a = try #require(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ))
        let b = try #require(await cache.read(
            ownerUserID: Self.ownerB,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ))
        #expect(a.lastPostedValue == 8345)
        #expect(b.lastPostedValue == 12)
        #expect(try await cache.totalRowCount() == 2)
    }

    // MARK: - Legacy quarantine

    @Test("An ownerless legacy row is retained, invisible, and never adopted")
    func legacyRowIsQuarantined() async throws {
        let cache = try makeCache()
        try await cache.insertLegacyRowForTesting(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345
        )

        // Invisible to every named account…
        #expect(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16"
        ) == nil)
        // …so the first sweep replays the day instead of inheriting it.
        let row = sampleRow(value: 8345)
        #expect(await cache.plan(ownerUserID: Self.ownerA, for: row) == .post(row: row))

        // …and it is still on disk, counted, and unlabelled.
        #expect(try await cache.quarantinedLegacyRowCount() == 1)
        #expect(try await cache.totalRowCount() == 1)

        // A write by the named account adds a row rather than relabelling one.
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 9000
        )
        #expect(try await cache.totalRowCount() == 2)
        #expect(try await cache.quarantinedLegacyRowCount() == 1)
    }

    // MARK: - sweepOlderThan + clearAll

    @Test("sweepOlderThan deletes only this owner's entries past the threshold")
    func sweepDropsOldRows() async throws {
        let cache = try makeCache()
        let now = Date()
        let oldDate = now.addingTimeInterval(-100 * 24 * 3600) // 100 days
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-01-01",
            lastPostedValue: 100,
            at: oldDate
        )
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345,
            at: now
        )
        // Account B has an equally old row; the sweep must not touch it.
        try await cache.write(
            ownerUserID: Self.ownerB,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-01-01",
            lastPostedValue: 7,
            at: oldDate
        )
        let dropped = try await cache.sweepOlderThan(90 * 24 * 3600, ownerUserID: Self.ownerA, now: now)
        #expect(dropped == 1)
        #expect(try await cache.count(ownerUserID: Self.ownerA) == 1)
        #expect(try await cache.count(ownerUserID: Self.ownerB) == 1)
        #expect(await cache.read(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-01-01"
        ) == nil)
    }

    @Test("clearAll wipes exactly one account's rows — logout sweep")
    func clearAllWipesOnlyTheNamedOwner() async throws {
        let cache = try makeCache()
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 8345
        )
        try await cache.write(
            ownerUserID: Self.ownerA,
            hkIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            dayKey: "2026-05-16",
            lastPostedValue: 412
        )
        try await cache.write(
            ownerUserID: Self.ownerB,
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayKey: "2026-05-16",
            lastPostedValue: 12
        )
        try await cache.insertLegacyRowForTesting(
            hkIdentifier: "HKQuantityTypeIdentifierFlightsClimbed",
            dayKey: "2026-05-16",
            lastPostedValue: 3
        )

        try await cache.clearAll(ownerUserID: Self.ownerA)

        #expect(try await cache.count(ownerUserID: Self.ownerA) == 0)
        #expect(try await cache.count(ownerUserID: Self.ownerB) == 1)
        // Logout of A does not destroy an unattributable row either.
        #expect(try await cache.quarantinedLegacyRowCount() == 1)
    }
}
