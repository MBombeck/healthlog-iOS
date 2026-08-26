import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    @Suite("HealthKitStatisticsSyncCoordinator — summary tallying + gate")
    struct HealthKitStatisticsSyncCoordinatorTests {
        // MARK: - Summary tallying

        @Test("tallying .post increments posted")
        func tallyPost() {
            let row = makeRow()
            let next = HealthKitStatisticsSyncSummary.complete.tallying(.post(row: row))
            #expect(next == HealthKitStatisticsSyncSummary(posted: 1, reposted: 0, skipped: 0, failed: 0))
        }

        /// **Restated.** This suite used to assert that `.patch` increments a
        /// `patched` counter. Both the arm and the counter are gone: the PATCH
        /// required a server row id the stats path never obtained, so it was
        /// unreachable in production. A divergent day total is now an `.upsert`
        /// of the same stable `stats:` identity, tallied as a repost.
        @Test("tallying .upsert increments reposted")
        func tallyUpsert() {
            let row = makeRow()
            let next = HealthKitStatisticsSyncSummary.complete.tallying(.upsert(row: row))
            #expect(next == HealthKitStatisticsSyncSummary(posted: 0, reposted: 1, skipped: 0, failed: 0))
        }

        @Test("tallying .skip increments skipped")
        func tallySkip() {
            let next = HealthKitStatisticsSyncSummary.complete.tallying(.skip(reason: "noop"))
            #expect(next == HealthKitStatisticsSyncSummary(posted: 0, reposted: 0, skipped: 1, failed: 0))
        }

        /// **Restated (Phase 07 / Plan 07-04).** This was `tallyingFailure`,
        /// which only bumped a counter. A failure is now two facts, not one:
        /// how many rows were not terminally accepted, and whether they survive
        /// a relaunch. Only the second decides whether the sweep may call the
        /// history complete.
        @Test("a held chunk is complete only when it was durably queued")
        func tallyHeld() {
            let queued = HealthKitStatisticsSyncSummary.complete.tallyingHeld(3, retryQueued: true)
            #expect(queued == HealthKitStatisticsSyncSummary(
                posted: 0, reposted: 0, skipped: 0, failed: 3, retryQueued: 3, isComplete: true
            ))

            let dropped = HealthKitStatisticsSyncSummary.complete.tallyingHeld(3, retryQueued: false)
            #expect(dropped == HealthKitStatisticsSyncSummary(
                posted: 0, reposted: 0, skipped: 0, failed: 3, retryQueued: 0, isComplete: false
            ))
        }

        @Test("incompleteness is sticky — a later success cannot restore it")
        func incompletenessIsSticky() {
            let row = makeRow()
            let summary = HealthKitStatisticsSyncSummary.complete
                .tallyingHeld(1, retryQueued: false)
                .tallying(.post(row: row))
                .tallyingHeld(1, retryQueued: true)
            #expect(!summary.isComplete)
            #expect(summary.posted == 1)
            #expect(summary.failed == 2)
            #expect(summary.retryQueued == 1)
        }

        @Test("a pass with no admission is not a complete pass")
        func heldPassIsNotComplete() {
            #expect(!HealthKitStatisticsSyncSummary.held.isComplete)
            #expect(HealthKitStatisticsSyncSummary.held.totalExecuted == 0)
            // The flag being off is a different statement: there is no history
            // this path owes, so the pass is complete in itself.
            #expect(HealthKitStatisticsSyncSummary.disabled.isComplete)
        }

        @Test("totalExecuted sums all four counters")
        func totalExecutedSums() {
            let summary = HealthKitStatisticsSyncSummary(posted: 3, reposted: 2, skipped: 5, failed: 1)
            #expect(summary.totalExecuted == 11)
        }

        // MARK: - Feature-flag gate

        @Test("sync() short-circuits when feature flag is OFF")
        func syncShortCircuitsWhenFlagOff() async throws {
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let stub = HKStatsStubAPIClient()
            let flags = HKStatsStubFeatureFlags(enableDailyStats: false)
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: Self.uploader(api: stub),
                featureFlags: flags
            )
            let summary = await coordinator.sync(lookbackDays: 1)
            #expect(summary.totalExecuted == 0)
            #expect(summary.isComplete, "the flag being off owes no history")
            #expect(await stub.requestCount() == 0, "No HTTP calls should fire when gate is OFF")
        }

        // MARK: - Admission gate (Phase 07 / Plan 07-04)

        @Test("sync() refuses outright when no account can be admitted")
        func syncRefusesWithoutAnAdmittedAccount() async throws {
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let stub = HKStatsStubAPIClient()
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: Self.uploader(api: stub),
                featureFlags: HKStatsStubFeatureFlags(enableDailyStats: true),
                admission: { throw HealthSyncLeaseRefusal.unavailableAuthentication }
            )
            let summary = await coordinator.sync(lookbackDays: 1)
            #expect(summary.totalExecuted == 0)
            #expect(!summary.isComplete, "a pass that never ran cannot claim the history is complete")
            #expect(await stub.requestCount() == 0, "A refused admission must not reach the wire")
            #expect(try await cache.totalRowCount() == 0, "A refused admission must not write cache state")
        }

        @Test("the cache sweep is a no-op without an admitted account")
        func sweepRefusesWithoutAnAdmittedAccount() async throws {
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            try await cache.write(
                ownerUserID: "account-a",
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayKey: "2026-01-01",
                lastPostedValue: 100,
                at: Date(timeIntervalSince1970: 0)
            )
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: Self.uploader(api: HKStatsStubAPIClient()),
                featureFlags: HKStatsStubFeatureFlags(enableDailyStats: true)
            )
            let swept = await coordinator.sweepCacheOlderThan(60, now: Date())
            #expect(swept == 0)
            #expect(try await cache.count(ownerUserID: "account-a") == 1, "another account's rows must survive")
        }

        // MARK: - Helpers

        static func uploader(api: APIClientProtocol) -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
        }

        private func makeRow() -> HealthKitDailyStatRow {
            HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: Date(timeIntervalSince1970: 1_716_000_000),
                dayKey: "2026-05-16",
                value: 8345,
                unit: "steps"
            )
        }
    }

    // MARK: - Test stubs

    /// Captures all sent requests for inspection in tests.
    actor HKStatsStubAPIClient: APIClientProtocol {
        private var requests: [String] = []

        func requestCount() -> Int {
            requests.count
        }

        func paths() -> [String] {
            requests
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            requests.append(request.path)
            // Default: throw — tests that exercise the success path use a richer fake.
            throw HLError.network(.other("HKStatsStubAPIClient send"))
        }

        func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
            requests.append(request.path)
        }

        func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            requests.append(request.path)
            throw HLError.network(.other("HKStatsStubAPIClient download"))
        }
    }

    struct HKStatsStubFeatureFlags: FeatureFlagsServicing {
        let enableDailyStats: Bool
        func isEnabled(_ flag: FeatureFlag) -> Bool {
            switch flag {
            case .enableDailyStats: enableDailyStats
            default: true
            }
        }
    }

#endif
