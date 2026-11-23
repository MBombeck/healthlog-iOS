import Foundation

#if canImport(HealthKit)

    extension HealthKitStatisticsSyncCoordinator {
        /// One type's day totals over `lookbackDays`, outside the regular
        /// sweep. It neither moves the sweep end nor reads the other types:
        /// it exists for a type that arrived after the account's all-time
        /// backfill had already run, whose history no 7-day sweep reaches.
        public func backfillDailyStats(identifier: String, lookbackDays: Int) async -> Bool {
            await serialized { await self.backfillType(identifier, lookbackDays: lookbackDays) }
        }

        private func backfillType(_ identifier: String, lookbackDays: Int) async -> Bool {
            guard let config = HealthKitCumulativeTypeConfig.defaults.first(where: { $0.identifier == identifier }),
                  let lease = admittedLease() else { return false }
            let now = clock()
            let from = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
            let rows: [HealthKitDailyStatRow]
            do {
                rows = try await statisticsService.dailyRows(for: config, from: from, to: now)
            } catch {
                // Not read is not done: the backfill stays owed.
                return false
            }
            return await process(rows, requiring: lease).isComplete
        }
    }

#endif
