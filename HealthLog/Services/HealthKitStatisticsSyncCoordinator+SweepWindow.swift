import Foundation

#if canImport(HealthKit)

    /// Build 273 — the sweep window (A12) and the durable-retry seam (A15),
    /// split out of the coordinator file so it stays under the file-length rule.
    extension HealthKitStatisticsSyncCoordinator {
        /// Build 273 (A12) — how far a catch-up from the last completed sweep may
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
        /// only when it is. #115 / 0.3 — a HealthKit query that threw did not
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
            return summary
        }

        func lastCompletedSweepEnd(ownerID: String) -> Date? {
            defaultsProvider().object(forKey: Self.lastSweepEndKey(ownerID: ownerID)) as? Date
        }

        func recordCompletedSweep(ownerID: String, endingAt end: Date) {
            defaultsProvider().set(end, forKey: Self.lastSweepEndKey(ownerID: ownerID))
        }

        func persistRetry(
            _ entries: [HealthKitBatchEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> Bool {
            guard let retry else { return false }
            guard let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: HealthSampleConsumption.stableIdentity(of: entries)
            ) else {
                return false
            }
            do {
                try lease.requireCurrent()
                // A15 — one row per key: an already pending retry counts as
                // queued and is not enqueued a second time.
                if await retry.hasPendingHealthKitRetry(idempotencyKey: envelope.idempotencyKey) {
                    return true
                }
                try await retry.enqueueHealthKitRetry(
                    entries,
                    idempotencyKey: envelope.idempotencyKey,
                    requiringCurrentOwner: lease.ownerID
                )
                try lease.requireCurrent()
                return true
            } catch {
                // No value, no identifier, no owner — only the fact that the
                // durable write did not happen, which is what keeps the sweep
                // incomplete.
                HLLog.healthKit.error("HK-STATS durable retry write failed — sweep stays incomplete")
                return false
            }
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
