import Foundation

/// **X4 (1.3, #138 / #77)** — the hourly backfill a pass hands its history
/// budget to. A separate protocol, so the day-total seam and its test stubs
/// stay as they are; ``HealthKitStatisticsSyncCoordinator`` is the only
/// production conformer.
public protocol HealthKitHourlyStatsBackfilling: AnyObject, Sendable {
    @discardableResult
    func runHourlyStatsBackfill(_ allowance: HourlyStatsBackfillAllowance) async -> HourlyStatsOutcome
}

#if canImport(HealthKit)

    /// **X4 — hourly `stats:` rows for the four summed types.**
    ///
    /// Two halves, both behind the server's `features.cumulativeHourBuckets`
    /// (``KnownServerVersion/supports(_:defaults:)``). Against any other server
    /// neither half reads HealthKit or sends a byte, so a v1.42 server sees
    /// exactly what 1.2 sent.
    ///
    /// - **Live** (``syncOpenHours(requiring:now:)``): today and yesterday, at
    ///   the end of every day-total sweep (V1's sweep, so on every trigger),
    ///   under the sweep's own trigger. Only hours whose value changed go out.
    /// - **Backfill** (``runHourlyStatsBackfill(_:)``): the 28 closed days
    ///   before that, newest first, labelled `backfill` where the server takes
    ///   it. It runs only in a pass's history budget and only after that pass's
    ///   sample collection (W2's live streams first), so it is never ahead of
    ///   live data.
    ///
    /// Neither half touches the day totals, their cache or their sweep end, and
    /// neither writes the outbox: an hour that did not land is simply sent
    /// again by the next run (the server overwrites, `updated`).
    extension HealthKitStatisticsSyncCoordinator: HealthKitHourlyStatsBackfilling {
        /// Today and yesterday stay open for late Watch samples.
        nonisolated static let hourlyOpenDays = 2
        /// Closed days the backfill owes: day offsets 2 ... 29, so together with
        /// the two open days the server holds 30 days of hours.
        nonisolated static let hourlyBackfillDayOffsets = Array(2 ..< 30)

        func hourlyGateOpen() -> Bool {
            featureFlags.isEnabled(.enableDailyStats)
                && KnownServerVersion.supports(.cumulativeHourBuckets, defaults: defaultsProvider())
        }

        // MARK: - Live

        /// Sends the changed hours of today and yesterday. Called at the end of
        /// every day-total sweep, inside the coordinator's serial lane.
        func syncOpenHours(requiring lease: HealthSyncAuthenticatedLease, now: Date) async {
            guard hourlyGateOpen(), let zone = await statisticsService.hourlyTimeZone() else { return }
            let calendar = Self.hourCalendar(zone)
            let today = calendar.startOfDay(for: now)
            let openStart = calendar.date(byAdding: .day, value: -(Self.hourlyOpenDays - 1), to: today) ?? today
            let read = await statisticsService.hourlyRows(from: openStart, through: now)
            guard let readZone = read.timeZoneIdentifier else { return }

            let defaults = defaultsProvider()
            var ledger = HourlyStatsLedgerStore.load(ownerID: lease.ownerID, defaults: defaults)
            ledger.adopt(timeZoneIdentifier: readZone)
            let openKeys = Set((0 ..< Self.hourlyOpenDays).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: today).map {
                    HealthKitStatisticsService.dayKey(for: $0, calendar: calendar)
                }
            })
            let changed = ledger.changedRows(read.rows.filter { openKeys.contains($0.dayKey) })
            var outcome: HourlyStatsOutcome = read.failedTypes > 0 ? .queryFailed : .upToDate
            if !changed.isEmpty {
                if await postHours(changed, requiring: lease) {
                    ledger.remember(changed)
                    ledger.lastLiveUploadAt = now
                    if outcome != .queryFailed { outcome = .uploaded }
                } else {
                    outcome = .uploadFailed
                }
            }
            ledger.lastLiveOutcome = outcome
            ledger.prune(before: Self.oldestKeptDayKey(today: today, calendar: calendar))
            HourlyStatsLedgerStore.save(ledger, ownerID: lease.ownerID, defaults: defaults)
            Self.logRun("live", outcome: outcome, rows: changed.count)
        }

        // MARK: - Backfill

        public func runHourlyStatsBackfill(_ allowance: HourlyStatsBackfillAllowance) async -> HourlyStatsOutcome {
            await serialized { await self.backfillHours(allowance) }
        }

        private func backfillHours(_ allowance: HourlyStatsBackfillAllowance) async -> HourlyStatsOutcome {
            guard hourlyGateOpen(), let zone = await statisticsService.hourlyTimeZone() else {
                return .serverUnsupported
            }
            guard let lease = admittedLease() else { return .notAdmitted }
            let deadline = ProcessInfo.processInfo.systemUptime + allowance.timeBudget
            let calendar = Self.hourCalendar(zone)
            let now = clock()
            let today = calendar.startOfDay(for: now)
            let defaults = defaultsProvider()
            var ledger = HourlyStatsLedgerStore.load(ownerID: lease.ownerID, defaults: defaults)
            ledger.adopt(timeZoneIdentifier: zone.identifier)
            ledger.prune(before: Self.oldestKeptDayKey(today: today, calendar: calendar))

            // Newest first, like W2's history walk.
            let owed: [(key: String, start: Date)] = Self.hourlyBackfillDayOffsets.compactMap { offset in
                guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let key = HealthKitStatisticsService.dayKey(for: start, calendar: calendar)
                return ledger.completedDays.contains(key) ? nil : (key, start)
            }
            let days = Array(owed.prefix(max(0, allowance.maxDays)))
            guard let newest = days.first, let oldest = days.last else {
                return finishBackfill(.upToDate, ledger: ledger, lease: lease, rows: 0)
            }
            let newestEnd = calendar.date(byAdding: .day, value: 1, to: newest.start)?.addingTimeInterval(-1) ?? newest.start
            let read = await statisticsService.hourlyRows(from: oldest.start, through: newestEnd)
            // A type that could not be read did not cover its days: nothing is
            // marked done, the next run reads them again.
            guard read.failedTypes == 0, read.timeZoneIdentifier == ledger.timeZoneIdentifier else {
                return finishBackfill(.queryFailed, ledger: ledger, lease: lease, rows: 0)
            }
            let byDay = Dictionary(grouping: read.rows, by: \.dayKey)
            var plan = HourlyBackfillPlan()
            for day in days {
                plan.add(day: day.key, rows: ledger.changedRows(byDay[day.key] ?? []))
            }
            return await sendBackfill(plan, ledger: ledger, lease: lease, allowance: allowance, deadline: deadline)
        }

        /// Sends the planned batches in order. A day is done once the batch
        /// that carries it landed (or it had nothing to send); a failed or
        /// expired batch stops the run and leaves its days owed.
        private func sendBackfill(
            _ plan: HourlyBackfillPlan,
            ledger: HourlyStatsLedger,
            lease: HealthSyncAuthenticatedLease,
            allowance: HourlyStatsBackfillAllowance,
            deadline: TimeInterval
        ) async -> HourlyStatsOutcome {
            var ledger = ledger
            ledger.completedDays.formUnion(plan.daysWithoutRows)
            for day in plan.daysWithoutRows {
                ledger.accepted[day] = nil
            }
            var sent = 0
            for batch in plan.batches {
                if Task.isCancelled || allowance.isExpired() || ProcessInfo.processInfo.systemUptime >= deadline {
                    return finishBackfill(.expired, ledger: ledger, lease: lease, rows: sent)
                }
                let landed = await postHours(batch.rows, requiring: lease, asBackfill: true)
                guard landed else {
                    return finishBackfill(.uploadFailed, ledger: ledger, lease: lease, rows: sent)
                }
                sent += batch.rows.count
                ledger.completedDays.formUnion(batch.days)
                for day in batch.days {
                    ledger.accepted[day] = nil
                }
                ledger.lastBackfillUploadAt = clock()
                HourlyStatsLedgerStore.save(ledger, ownerID: lease.ownerID, defaults: defaultsProvider())
            }
            return finishBackfill(sent > 0 ? .uploaded : .upToDate, ledger: ledger, lease: lease, rows: sent)
        }

        private func finishBackfill(
            _ outcome: HourlyStatsOutcome,
            ledger: HourlyStatsLedger,
            lease: HealthSyncAuthenticatedLease,
            rows: Int
        ) -> HourlyStatsOutcome {
            var ledger = ledger
            ledger.lastBackfillOutcome = outcome
            HourlyStatsLedgerStore.save(ledger, ownerID: lease.ownerID, defaults: defaultsProvider())
            Self.logRun("backfill", outcome: outcome, rows: rows)
            return outcome
        }

        // MARK: - Transport

        /// One batch through the shared uploader (same throttle, backoff,
        /// idempotency key and acceptance gate as every measurement batch).
        /// `true` only when every row landed terminally for the same account.
        /// SYNC-TRIG (1.5) — `asBackfill` marks the batch on the upload call.
        func postHours(
            _ rows: [HealthKitHourlyStatRow],
            requiring lease: HealthSyncAuthenticatedLease,
            asBackfill: Bool = false
        ) async -> Bool {
            do {
                try lease.requireCurrent()
                let authLease = try await uploader.captureAuthenticationLeaseIfConfigured()
                _ = try await uploader.upload(rows.map(\.entry), requiring: authLease, asBackfill: asBackfill)
                try lease.requireCurrent()
                return true
            } catch {
                // The error's type only: a message can carry a value or a date.
                let errorType = String(describing: type(of: error))
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error("HK-HOURLY upload not accepted — error=\(errorType, privacy: .public)")
                return false
            }
        }

        // MARK: - Helpers

        nonisolated static func hourCalendar(_ zone: TimeZone) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }

        /// The oldest day the ledger still needs: the last owed backfill day.
        nonisolated static func oldestKeptDayKey(today: Date, calendar: Calendar) -> String {
            let offset = hourlyBackfillDayOffsets.last ?? 0
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return HealthKitStatisticsService.dayKey(for: day, calendar: calendar)
        }

        nonisolated static func logRun(_ half: String, outcome: HourlyStatsOutcome, rows: Int) {
            // A fixed word, an enum case and a count: no value, date or account.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit
                .notice(
                    "HK-HOURLY \(half, privacy: .public) — outcome=\(outcome.rawValue, privacy: .public) rows=\(rows, privacy: .public)"
                )
        }
    }

    /// The backfill's batches: whole days, newest first, at most one server
    /// batch (500 rows) each, so the two starts of a repeated autumn hour can
    /// never be split across two requests.
    struct HourlyBackfillPlan {
        struct Batch {
            var days: [String] = []
            var rows: [HealthKitHourlyStatRow] = []
        }

        private(set) var batches: [Batch] = []
        private(set) var daysWithoutRows: [String] = []

        mutating func add(day: String, rows: [HealthKitHourlyStatRow]) {
            guard !rows.isEmpty else {
                daysWithoutRows.append(day)
                return
            }
            if var last = batches.last, last.rows.count + rows.count <= MeasurementBatchUploader.maxEntriesPerBatch {
                last.days.append(day)
                last.rows += rows
                batches[batches.count - 1] = last
            } else {
                batches.append(Batch(days: [day], rows: rows))
            }
        }
    }

#endif
