import Foundation

extension AppContainer {
    /// The hourly 30-day backfill a pass may run.
    ///
    /// Only where the pass may walk history at all (W2's budget: foreground,
    /// manual, cold start, after sign-in, BGProcessing; never App-Refresh,
    /// silent push or an observer delivery), with the same time allowance as
    /// that history walk. BGProcessing may send every owed day at once; an app
    /// open sends at most a week, so a fresh install spreads its 28 days over a
    /// few opens instead of one long first pass.
    nonisolated static func hourlyBackfillAllowance(for context: HealthSyncRunContext) -> HourlyStatsBackfillAllowance? {
        guard context.budget.allowsFirstHistoryImport, context.budget.historyTimeBudget > 0 else { return nil }
        let maxDays = context.trigger == .processing ? hourlyBackfillDaysPerProcessingPass : hourlyBackfillDaysPerPass
        return HourlyStatsBackfillAllowance(
            maxDays: maxDays,
            timeBudget: context.budget.historyTimeBudget,
            isExpired: context.isExpired
        )
    }

    nonisolated static let hourlyBackfillDaysPerPass = 7
    nonisolated static let hourlyBackfillDaysPerProcessingPass = 28

    #if canImport(HealthKit) && canImport(SpeziHealthKit)
        /// The sample collection (W2: live streams first, then history), and
        /// after it, in what is left of the pass, the hourly backfill. That
        /// order is the point: the backfill is history and never runs ahead of
        /// live data. The capability reports the collection's result; the
        /// backfill keeps its own outcome for Sync Diagnostics.
        nonisolated static func runSampleCollectionThenHourlyBackfill(
            _ context: HealthSyncRunContext,
            hourly: (any HealthKitDailyStatsSyncing)?
        ) async -> HealthSyncCapabilityResult {
            let result = await AppOwnedHealthCollection.runSampleCollection(context.trigger)
            if let backfill = hourly as? any HealthKitHourlyStatsBackfilling,
               let allowance = hourlyBackfillAllowance(for: context),
               !context.isCancelledOrExpired
            {
                await backfill.runHourlyStatsBackfill(allowance)
            }
            return result
        }
    #endif
}
