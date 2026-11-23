#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// D4-5 — sign-out drops the leaving account's last-posted day totals and
    /// nobody else's.
    @Suite("Daily-stats cache — sign-out clears one account", .mockURLSession)
    struct HealthKitStatsSignOutClearTests {
        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app", appVersion: "0.1.0", buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        @Test("clearing the cache on sign-out drops one account's rows")
        func signOutClearsOneAccount() async throws {
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            for owner in ["account-a", "account-b"] {
                try await cache.write(
                    ownerUserID: owner, hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                    dayKey: "2026-05-16", lastPostedValue: 8345
                )
            }
            let coordinator = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: MeasurementBatchUploader(
                    api: makeAPI(),
                    throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
                )
            )
            await coordinator.clearCache(ownerUserID: "account-a")
            #expect(try await cache.count(ownerUserID: "account-a") == 0)
            #expect(try await cache.count(ownerUserID: "account-b") == 1)
        }
    }
#endif
