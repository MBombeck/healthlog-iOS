import Foundation

#if canImport(HealthKit)

    /// **V1 (1.2)** — the HealthKit read behind the daily-statistics sweep, as
    /// a seam, so a test can drive a whole sweep (read, plan, upload, trigger
    /// label) without a health store. ``HealthKitStatisticsService`` is the only
    /// production conformer.
    public protocol HealthKitDailyStatsReading: Sendable {
        func dailyRowsForAllDefaults(from: Date, to: Date) async -> HealthKitDailyStatsRead
        func dailyRows(
            for config: HealthKitCumulativeTypeConfig,
            from: Date,
            to: Date
        ) async throws -> [HealthKitDailyStatRow]
    }

    extension HealthKitStatisticsService: HealthKitDailyStatsReading {}

    /// **V1 (1.2, #66 / HealthLog#1173) — the requested recent sweep.**
    ///
    /// Until 1.1.1 the day totals had no trigger of their own: they ran only as
    /// one capability of a full orchestrated pass, which the foreground deadline
    /// cancelled and which AppRefresh, silent push and HealthKit deliveries did
    /// not plan. A step delivery is dropped from the per-sample batch (the
    /// statistics own it), so nothing replaced it until "Sync all". The same
    /// shape T2 gave the pulse buckets: dropping a cumulative sample and asking
    /// for the sweep that replaces it are now one step.
    extension HealthKitStatisticsSyncCoordinator {
        /// Today and yesterday in the profile zone (`from` = now minus one day,
        /// floored to that day's start by the statistics service). Watch samples
        /// arrive late, so yesterday stays open.
        nonisolated static let recentLookbackDays = 1

        public func requestRecentDailyStatsSweep(trigger: SyncTrigger) async {
            if recentSweep != nil {
                if recentRerun == nil { recentRerun = trigger }
                return
            }
            // Detached: the requester's cancellation (a foreground deadline, an
            // expiring wake) must not cut the upload it asked for.
            recentSweep = Task.detached { [weak self] in
                guard let self else { return }
                await runRecentSweeps(first: trigger)
            }
        }

        public func awaitRequestedDailyStatsSweeps() async {
            while let sweep = recentSweep {
                await sweep.value
            }
        }

        private func runRecentSweeps(first: SyncTrigger) async {
            var next: SyncTrigger? = first
            while let trigger = next {
                recentRerun = nil
                await SyncTriggerContext.shared.bind(trigger) {
                    _ = await self.sync(lookbackDays: Self.recentLookbackDays)
                }
                next = recentRerun
            }
            recentSweep = nil
        }

        /// One sweep at a time. Each body runs in a task chained behind the
        /// previous one; the caller's cancellation is forwarded to it, so an
        /// expiring background grant still stops its own sweep.
        func serialized<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
            let previous = laneTail
            let task = Task {
                await previous?.value
                return await body()
            }
            laneTail = Task { _ = await task.value }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }

        /// v0.6.2.x bug-c10-ios-direct — see protocol doc. (Moved here
        /// unchanged in V1 for the coordinator file's length.) Reads today's
        /// step cumulative directly from HK so the dashboard tile + chart-
        /// detail today-segment can paint live values instead of the
        /// server's frozen day-row. Anchored on `Calendar.current`'s start-
        /// of-day (user-TZ) up to `clock()` so the bucket math matches the
        /// existing sync path. Returns `nil` (not `0`) on any HK error so
        /// the caller's nil-coalescing fallback to the server snapshot
        /// stays in place — `0` would override a non-empty server value.
        public func liveTodayStepCount() async -> Double? {
            let now = clock()
            let stepConfig = HealthKitCumulativeTypeConfig(
                identifier: "HKQuantityTypeIdentifierStepCount",
                wireUnit: "steps"
            )
            do {
                let rows = try await statisticsService.dailyRows(
                    for: stepConfig,
                    from: now,
                    to: now
                )
                // `dailyRows` skips 0-value buckets and the from/to are both
                // today, so a non-empty result is exactly today's cumulative.
                return rows.first?.value
            } catch {
                HLLog.healthKit
                    .debug(
                        "liveTodayStepCount HK-read failed: \(error.localizedDescription, privacy: .public)"
                    )
                return nil
            }
        }

        func recordUploads(_ uploads: [String: Int], ownerID: String) {
            let trigger = SyncTriggerContext.shared.current
            let at = clock()
            for (identifier, count) in uploads {
                HealthKitStatsUploadLogStore.recordUpload(
                    identifier: identifier,
                    count: count,
                    trigger: trigger,
                    at: at,
                    ownerID: ownerID,
                    defaults: defaultsProvider()
                )
            }
        }
    }

#endif
