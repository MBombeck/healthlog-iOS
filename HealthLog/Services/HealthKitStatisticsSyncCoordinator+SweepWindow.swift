import Foundation

#if canImport(HealthKit)

    /// The sweep window and the durable-retry seam,
    /// split out of the coordinator file so it stays under the file-length rule.
    extension HealthKitStatisticsSyncCoordinator {
        /// How far a catch-up from the last completed sweep may
        /// reach back. Day totals are not an incremental partition, so a fixed
        /// lookback left every day between the last sweep and the lookback edge
        /// unsynced after a dormancy longer than the lookback.
        nonisolated static let maxCatchUpDays = 30
        nonisolated static let lastSweepEndKeyPrefix = "hl.healthkit.dailyStatsLastSweepEndUTC."

        /// The sweep's `from`: never narrower than the lookback, and — once a
        /// sweep has completed — never later than one day before that sweep's
        /// end, bounded at ``maxCatchUpDays``.
        nonisolated static func sweepWindowStart(
            now: Date,
            lookbackDays: Int,
            lastCompletedSweepEnd: Date?,
            calendar: Calendar
        ) -> Date {
            let lookbackFrom = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
            guard let lastCompletedSweepEnd else { return lookbackFrom }
            let overlap = calendar.date(byAdding: .day, value: -1, to: lastCompletedSweepEnd) ?? lastCompletedSweepEnd
            let bound = calendar.date(byAdding: .day, value: -maxCatchUpDays, to: now) ?? now
            return min(lookbackFrom, max(overlap, bound))
        }

        nonisolated static func lastSweepEndKey(ownerID: String) -> String {
            lastSweepEndKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
        }

        /// Transmits what the read produced and records the sweep as complete
        /// only when it is. A HealthKit query that threw did not
        /// read its window: the rows that were read still go out, but the sweep
        /// end stays where it was, so the next sweep reads the window again
        /// (and the orchestrator does not burn the all-time backfill one-shot).
        func finishSweep(
            _ read: HealthKitDailyStatsRead,
            requiring lease: HealthSyncAuthenticatedLease,
            endingAt now: Date
        ) async -> HealthKitStatisticsSyncSummary {
            var summary = await process(read.rows, requiring: lease)
            if read.failedTypes > 0 {
                summary = summary.markingIncomplete()
            }
            if summary.isComplete {
                recordCompletedSweep(ownerID: lease.ownerID, endingAt: now)
            }
            // The hours of today and yesterday ride every
            // sweep, after the day totals and apart from them: they never move
            // this sweep's summary, its cache or its end.
            await syncOpenHours(requiring: lease, now: now)
            return summary
        }

        func lastCompletedSweepEnd(ownerID: String) -> Date? {
            defaultsProvider().object(forKey: Self.lastSweepEndKey(ownerID: ownerID)) as? Date
        }

        func recordCompletedSweep(ownerID: String, endingAt end: Date) {
            defaultsProvider().set(end, forKey: Self.lastSweepEndKey(ownerID: ownerID))
        }

        /// #8 — the sweep's `from`, reaching back to the oldest dirty day.
        nonisolated static func sweepFrom(
            _ windowStart: Date,
            dirty: HealthKitStatsDirtyDays.Mark?,
            calendar: Calendar
        ) -> Date {
            guard let dirty else { return windowStart }
            return min(windowStart, calendar.startOfDay(for: dirty.from))
        }

        /// #3 — an older build queued day totals in the outbox. They go, and
        /// their oldest day is marked dirty so this sweep sums it again from
        /// HealthKit, however far back it lies.
        func dropQueuedDayTotals(requiring lease: HealthSyncAuthenticatedLease) async {
            guard let retry, (try? lease.requireCurrent()) != nil else { return }
            let dropped = await retry.pruneQueuedHealthKitEntries(ownerUserID: lease.ownerID) {
                $0.externalId.hasPrefix(MeasurementBatchAcceptance.stableStatIdentityPrefix)
            }
            guard let oldest = dropped.map(\.startDate).min() else { return }
            HealthKitStatsDirtyDays.mark(oldest, ownerID: lease.ownerID, defaults: defaultsProvider())
            // A count only.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("HK-STATS \(dropped.count, privacy: .public) queued day total(s) dropped, summed again")
        }

        /// #3 — the server confirmed `entries`; a row still waiting with the
        /// same ids would only put an older value back later.
        func dropQueuedEntries(
            _ entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async {
            guard let retry, !entries.isEmpty else { return }
            let ids = Set(entries.map(\.externalId))
            _ = await retry.pruneQueuedHealthKitEntries(ownerUserID: lease.ownerID) { ids.contains($0.externalId) }
        }

        /// #8 — `read` plus a `0` for every day in the window this account
        /// posted with a value that the read no longer returns (the samples of
        /// that day were deleted in Health). Sent once: the cache then holds 0.
        ///
        /// Only for a type that still has rows elsewhere in the window: a type
        /// whose whole window reads empty although it had totals looks exactly
        /// like revoked read access, and nothing is sent for it (the rule the
        /// nutrient macros follow, `NutrientMacroDayLedger`).
        func withEmptiedDays(
            _ read: HealthKitDailyStatsRead,
            from: Date,
            to now: Date,
            ownerID: String
        ) async -> HealthKitDailyStatsRead {
            let sample = Dictionary(read.rows.map { ($0.hkIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            guard !sample.isEmpty else { return read }
            let present = Set(read.rows.map { $0.hkIdentifier + "|" + $0.dayKey })
            var corrected = read.rows
            for (identifier, model) in sample {
                let zone = model.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
                var dayCalendar = Calendar(identifier: .gregorian)
                dayCalendar.timeZone = zone
                let fromKey = HealthKitStatisticsService.dayKey(for: from, calendar: dayCalendar)
                let toKey = HealthKitStatisticsService.dayKey(for: now, calendar: dayCalendar)
                let posted = await (try? cache().postedDays(ownerUserID: ownerID, fromDayKey: fromKey, toDayKey: toKey)) ?? []
                for day in posted where day.hkIdentifier == identifier && !present.contains(identifier + "|" + day.dayKey) {
                    guard let dayStart = Self.dayStart(of: day.dayKey, calendar: dayCalendar) else { continue }
                    corrected.append(HealthKitDailyStatRow(
                        hkIdentifier: identifier,
                        dayStart: dayStart,
                        dayKey: day.dayKey,
                        value: 0,
                        unit: model.unit,
                        timeZoneIdentifier: model.timeZoneIdentifier
                    ))
                }
            }
            guard corrected.count > read.rows.count else { return read }
            // A count only.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("HK-STATS \(corrected.count - read.rows.count, privacy: .public) emptied day(s) sent as 0")
            return HealthKitDailyStatsRead(rows: corrected, failedTypes: read.failedTypes)
        }

        /// Local midnight of a `yyyy-MM-dd` key in `calendar`'s zone.
        nonisolated static func dayStart(of dayKey: String, calendar: Calendar) -> Date? {
            let parts = dayKey.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
    }

    /// **#8 — days whose total changed outside the sweep window.**
    ///
    /// A summed sample that arrives late (a distance logged for three weeks
    /// ago) moves the live anchor, but the day-total sweep reads only its
    /// window, at most 30 days. The oldest such day is remembered per account
    /// and the next sweep reaches back to it; a completed sweep forgets it,
    /// unless a newer mark arrived meanwhile (`generation`).
    enum HealthKitStatsDirtyDays {
        struct Mark: Equatable, Sendable {
            let from: Date
            let generation: Int
        }

        static let keyPrefix = "hl.healthkit.dailyStatsDirtyFrom."

        static func key(ownerID: String) -> String {
            keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
        }

        static func mark(_ date: Date, ownerID: String, defaults: UserDefaults) {
            let existing = read(ownerID: ownerID, defaults: defaults)
            let from = min(existing?.from ?? date, date)
            defaults.set(from, forKey: key(ownerID: ownerID))
            defaults.set((existing?.generation ?? 0) + 1, forKey: key(ownerID: ownerID) + ".generation")
        }

        static func read(ownerID: String, defaults: UserDefaults) -> Mark? {
            guard let from = defaults.object(forKey: key(ownerID: ownerID)) as? Date else { return nil }
            return Mark(from: from, generation: defaults.integer(forKey: key(ownerID: ownerID) + ".generation"))
        }

        /// Forgets `mark` once a sweep read it, never a later one.
        static func clear(_ mark: Mark, ownerID: String, defaults: UserDefaults) {
            guard read(ownerID: ownerID, defaults: defaults) == mark else { return }
            defaults.removeObject(forKey: key(ownerID: ownerID))
            defaults.removeObject(forKey: key(ownerID: ownerID) + ".generation")
        }
    }

    public extension HealthKitStatisticsSyncSummary {
        /// The window was not fully read. Sticky, like every incompleteness.
        func markingIncomplete() -> HealthKitStatisticsSyncSummary {
            HealthKitStatisticsSyncSummary(
                posted: posted,
                reposted: reposted,
                skipped: skipped,
                failed: failed,
                retryQueued: retryQueued,
                isComplete: false
            )
        }
    }

#endif
