#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// Build 273 (A15) — a deterministically failing stats chunk is re-planned on
    /// every foreground and used to be enqueued again each time under the SAME
    /// derived idempotency key (`OutboxStore.enqueue` inserts unconditionally).
    /// The coordinator must ask the retry queue first and treat an already
    /// pending row as queued.
    @Suite("Daily-stats retry — no duplicate outbox rows under one key")
    struct HealthKitStatsRetryDedupeTests {
        static let owner = "account-a"

        actor PendingAwareRetryQueue: HealthSyncBatchRetryEnqueuing {
            private(set) var enqueued: [String] = []
            private let pending: Set<String>
            init(pending: Set<String>) {
                self.pending = pending
            }

            func enqueueHealthKitRetry(_: [HealthKitBatchEntryDTO], idempotencyKey: String, requiringCurrentOwner _: String) async throws {
                enqueued.append(idempotencyKey)
            }

            func hasPendingHealthKitRetry(idempotencyKey: String) async -> Bool {
                pending.contains(idempotencyKey)
            }
        }

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app", appVersion: "0.1.0", buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        private func respondFailed() {
            MockURLProtocol.handler = { req in
                let body = #"""
                {"data":{"processed":1,"inserted":0,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"failed","reason":"persistence_error"}]},"error":null}
                """#
                // swiftlint:disable:next force_unwrapping
                let response = HTTPURLResponse(
                    url: req.url ?? URL(fileURLWithPath: "/"),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ) ?? HTTPURLResponse()
                return (response, Data(body.utf8))
            }
        }

        @Test("an already pending key is not enqueued again, and still counts as queued")
        func pendingKeyIsNotDuplicated() async throws {
            let row = HealthKitDailyStatRow(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                dayStart: Date(timeIntervalSince1970: 1_716_000_000), dayKey: "2026-05-16", value: 8345, unit: "steps"
            )
            let expected = HealthSyncRetryEnvelope(
                ownerID: Self.owner, source: .dailyStatistics,
                stableIdentity: "stats:HKQuantityTypeIdentifierStepCount:2026-05-16"
            )
            let retry = PendingAwareRetryQueue(pending: [expected?.idempotencyKey ?? ""])
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry, ownerID: Self.owner, source: .dailyStatistics, bearerProvider: { "bearer-a" }
            )
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: MeasurementBatchUploader(
                    api: makeAPI(),
                    throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
                ),
                featureFlags: AlwaysOnFeatureFlags(),
                admission: { lease },
                retry: retry
            )
            respondFailed()
            let summary = await coordinator.process([row], requiring: lease)
            #expect(summary.retryQueued == 1)
            #expect(await retry.enqueued.isEmpty, "the pending row must not be enqueued a second time")
        }
    }
#endif
