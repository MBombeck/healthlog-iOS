import Foundation
@testable import HealthLog
import Testing

/// Build 273 (A8) — the all-time daily-stats backfill one-shot may only be
/// burnt when the sweep actually completed. `triggerDailyStatsSync` used to
/// return `Void` and the orchestrator burnt the flag unconditionally after it
/// returned, so a wake killed mid-sweep (or a held sweep) left every later
/// sweep at 7 days and the historical day-rows never arrived.
@Suite("Daily-stats all-time backfill — one-shot burns only on completion")
struct HealthKitDailyStatsBackfillOneShotTests {
    @Test("a held sweep (no admitted account) reports incomplete")
    func heldSweepReportsIncomplete() async throws {
        #if canImport(HealthKit)
            let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
            let coord = HealthKitStatisticsSyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                cache: cache,
                uploader: MeasurementBatchUploader(
                    api: APIClient(
                        environment: AppEnvironment(
                            baseURL: URL(string: "https://test.healthlog.local"),
                            bundleID: "dev.healthlog.app",
                            appVersion: "0.1.0",
                            buildNumber: "1"
                        ),
                        keychain: InMemoryKeychain(),
                        sessionConfiguration: .mock()
                    ),
                    throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
                ),
                featureFlags: AlwaysOnFeatureFlags(),
                admission: { throw HLError.unknown("held: no admitted account") }
            )
            let syncing: HealthKitDailyStatsSyncing = coord
            let completed: Bool = await syncing.triggerDailyStatsSync(lookbackDays: 7)
            #expect(completed == false)
        #endif
    }

    @Test("the one-shot decision: burn only for a full pass that completed")
    func burnDecision() {
        #expect(AppContainer.shouldBurnDailyStatsAllTimeBackfill(incrementalOnly: false, completed: true))
        #expect(!AppContainer.shouldBurnDailyStatsAllTimeBackfill(incrementalOnly: false, completed: false))
        #expect(!AppContainer.shouldBurnDailyStatsAllTimeBackfill(incrementalOnly: true, completed: true))
    }
}
