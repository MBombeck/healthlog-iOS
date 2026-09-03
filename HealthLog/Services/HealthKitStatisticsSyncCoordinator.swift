import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Platform-agnostic seam fuer den HK-STATS-Coordinator. Lebt ausserhalb des
/// `#if canImport(HealthKit)`-Blocks, damit `AppContainer` einen
/// `HealthKitDailyStatsSyncing?`-Slot deklarieren kann, ohne dass der
/// SPM-Library-Build (HealthLogCore, ohne HK-Framework) bricht. Die einzige
/// Surface ist `sync(lookbackDays:)` — der Coordinator selbst (mit `actor`-
/// Isolation + HKHealthStore-Anbindung) ist iOS-only.
public protocol HealthKitDailyStatsSyncing: AnyObject, Sendable {
    /// Default-Sync: alle kumulativen Types in einem `lookbackDays`-Window
    /// hochziehen. Implementierungen entscheiden ueber die Behandlung von
    /// Per-Type-Fehlern (best-effort vs hard-fail). Fire-and-forget — der
    /// Caller (`BackgroundSyncCoordinator`, `AppContainer`-Bootstrap) braucht
    /// keine Summary-Counter, die landen im Log.
    /// Build 273 (A8) — reports whether the sweep COMPLETED (every row either
    /// landed or is durably queued). The orchestrator burns the all-time
    /// backfill one-shot only on `true`.
    @discardableResult
    func triggerDailyStatsSync(lookbackDays: Int) async -> Bool

    /// v0.6.2.x bug-c10-ios-direct — read today's cumulative step total
    /// straight from HealthKit, bypassing the server-snapshot path. The
    /// server's `/api/measurements/batch` is insert-only on the
    /// `(type, externalId="stats:HKQuantityTypeIdentifierStepCount:<day>")`
    /// pair, so any same-day update after the first sync is dropped as
    /// `duplicate`. The dashboard tile + chart-detail screen call this for
    /// the "today" segment so the operator's freshly-walked steps render
    /// even when the server row is frozen. Returns `nil` on simulator,
    /// missing permission, or any HK failure — callers fall back to the
    /// existing server-snapshot path. Default impl returns `nil` so test
    /// stubs (e.g. `RecordingSyncing` in `HealthKitDailyStatsWiringTests`)
    /// keep building unchanged.
    func liveTodayStepCount() async -> Double?

    /// **v0.12 W8-4** — Sweep der Daily-Stats-Cache-Rows aelter als `maxAge`.
    /// Best-effort, fire-and-forget aus dem BGTask-Cache-Sweep-Hook. Default-
    /// Impl ist ein No-op (Return `0`), damit Test-Stubs unveraendert bauen.
    @discardableResult
    func sweepCacheOlderThan(_ maxAge: TimeInterval, now: Date) async -> Int
}

public extension HealthKitDailyStatsSyncing {
    func liveTodayStepCount() async -> Double? {
        nil
    }

    @discardableResult
    func sweepCacheOlderThan(_: TimeInterval, now _: Date = .now) async -> Int {
        0
    }
}

#if canImport(HealthKit)

    /// Top-Level-Coordinator fuer den HK-STATS-Pfad. Verkettet
    /// `HealthKitStatisticsService` (HK-Query) → `HealthKitDailyStatsCache`
    /// (plan-Action-Auswahl) → `MeasurementBatchUploader` (gebuendelter POST
    /// mit exakter Acceptance) und schreibt den bestaetigten Tagestotal zurueck
    /// in die Owner-Partition des Caches.
    ///
    /// **Aufruf-Pfade:**
    /// - Foreground-Bootstrap nach Login.
    /// - BGProcessingTask-Wake.
    /// - HK-Observer-Wakeup fuer einen kumulativen Type (filter-handoff vom
    ///   `HealthKitService.handleNewSamples` — siehe FeatureFlag-Gate
    ///   `enableDailyStats`).
    ///
    /// Der Service ist `Sendable` actor-isolated, damit er gefahrlos vom
    /// Composition-Root in mehrere Konsumenten-Sites injectable ist.
    public actor HealthKitStatisticsSyncCoordinator {
        /// Deferred-open state for the daily-stats cache. Mirrors
        /// `SWRCoordinator.CacheState`: production defers the SwiftData
        /// `ModelContainer` open off the cold-launch tick (audit P-1) via
        /// `init(cacheTask:)`, resolving lazily on the first sync / sweep;
        /// tests seed `.resolved` directly via `init(cache:)`.
        private enum CacheState {
            case pending(Task<HealthKitDailyStatsCache, Never>)
            case resolved(HealthKitDailyStatsCache)
        }

        private let statisticsService: HealthKitStatisticsService
        private var cacheState: CacheState
        /// **Phase 07 / Plan 07-04** — the shared measurement uploader, not a
        /// private `APIClient` call. The stats path used to hand-roll its own
        /// POST, which meant it had its own idempotency key minting, no throttle
        /// share, no backoff share, and — before this plan — no acceptance gate
        /// at all. It now runs the same transmission every other measurement
        /// batch runs, chunked at the same server limit.
        private let uploader: MeasurementBatchUploader
        /// The durable-retry seam. `nil` in contexts with no queue (tests,
        /// pre-composition): a chunk that needs a retry and has nowhere to write
        /// it leaves the sweep incomplete rather than claiming ground.
        let retry: (any HealthSyncBatchRetryEnqueuing)?
        private let featureFlags: FeatureFlagsServicing
        private let calendar: Calendar
        private let clock: @Sendable () -> Date
        /// **Phase 07 / Plan 07-04** — the only place this coordinator learns
        /// which account it is working for.
        ///
        /// A closure, evaluated fresh at the start of every sweep, exactly like
        /// `AppContainer.installAppOwnedHealthCollection`: the signed-in user and
        /// the bearer paired with it are read once and pinned for the pass, and a
        /// signed-out process syncs nothing rather than syncing under whoever
        /// signed in last. `nil` only in contexts with no session at all (unit
        /// tests, pre-composition), where every pass refuses.
        private let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)?

        /// Internal rather than `public`: the admission is a
        /// `HealthSyncAuthenticatedLease`, and Phase 07 keeps that type inside
        /// the module. The composition root and the tests are both in-module.
        init(
            statisticsService: HealthKitStatisticsService,
            cache: HealthKitDailyStatsCache,
            uploader: MeasurementBatchUploader,
            featureFlags: FeatureFlagsServicing,
            calendar: Calendar = .current,
            clock: @escaping @Sendable () -> Date = { Date() },
            admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = nil,
            retry: (any HealthSyncBatchRetryEnqueuing)? = nil,
            defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
        ) {
            self.statisticsService = statisticsService
            cacheState = .resolved(cache)
            self.uploader = uploader
            self.retry = retry
            self.featureFlags = featureFlags
            self.calendar = calendar
            self.clock = clock
            self.admission = admission
            self.defaultsProvider = defaultsProvider
        }

        /// Production init — defers the daily-stats cache open until the first
        /// sync / sweep. `AppContainer` kicks the `ModelContainer` open onto a
        /// detached task (`HealthKitDailyStatsCache.makeWithRecoveryTask()`) so
        /// the cold-launch tick never pays for the SwiftData open (audit P-1).
        init(
            statisticsService: HealthKitStatisticsService,
            cacheTask: Task<HealthKitDailyStatsCache, Never>,
            uploader: MeasurementBatchUploader,
            featureFlags: FeatureFlagsServicing,
            calendar: Calendar = .current,
            clock: @escaping @Sendable () -> Date = { Date() },
            admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = nil,
            retry: (any HealthSyncBatchRetryEnqueuing)? = nil,
            defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
        ) {
            self.statisticsService = statisticsService
            cacheState = .pending(cacheTask)
            self.uploader = uploader
            self.retry = retry
            self.featureFlags = featureFlags
            self.calendar = calendar
            self.clock = clock
            self.admission = admission
            self.defaultsProvider = defaultsProvider
        }

        /// Single-flight resolve of the deferred cache. First call awaits the
        /// open; later calls return the memoised reference. Mirrors
        /// `SWRCoordinator.cache()`.
        let defaultsProvider: @Sendable () -> UserDefaults

        private func cache() async -> HealthKitDailyStatsCache {
            switch cacheState {
            case let .resolved(cache):
                return cache
            case let .pending(task):
                let value = await task.value
                cacheState = .resolved(value)
                return value
            }
        }

        /// Default-Sync: alle 5 cumulative types, Tage in `lookbackDays`-Window
        /// inkl. heute. Liefert eine Zusammenfassung der ausgefuehrten
        /// Actions — Tests inspizieren die Zaehler.
        ///
        /// **Phase 07 / Plan 07-04 — der Sweep ist erst fertig, wenn er es ist.**
        /// Die Rows eines Passes gehen gebuendelt ueber den geteilten
        /// `MeasurementBatchUploader` (derselbe Idempotency-/Throttle-/Backoff-
        /// Pfad wie der Per-Sample-Pfad, gechunkt auf das Server-Limit). Ein
        /// Chunk, der nicht terminal akzeptiert wird, wird als owner-gebundene
        /// Outbox-Row unter einem *abgeleiteten* Idempotency-Key nachgereicht;
        /// gelingt auch das nicht, ist der Sweep ``HealthKitStatisticsSyncSummary/isComplete``
        /// `false` und der Cache behaelt die alten Werte.
        @discardableResult
        public func sync(lookbackDays: Int = 7) async -> HealthKitStatisticsSyncSummary {
            guard featureFlags.isEnabled(.enableDailyStats) else {
                HLLog.healthKit
                    .debug("HK-STATS sync skipped — enableDailyStats flag is OFF")
                return .disabled
            }
            // The account this whole sweep belongs to, captured once. Every cache
            // read and every cache write below is keyed by it; there is no other
            // way for this coordinator to name an owner.
            guard let lease = admittedLease() else {
                HLLog.healthKit
                    .debug("HK-STATS sync skipped — no admitted account")
                return .held
            }

            let now = clock()
            let from = Self.sweepWindowStart(
                now: now,
                lookbackDays: lookbackDays,
                lastCompletedSweepEnd: lastCompletedSweepEnd(ownerID: lease.ownerID),
                calendar: calendar
            )
            let rowsByType = await statisticsService.dailyRowsForAllDefaults(from: from, to: now)
            let summary = await process(rowsByType.values.flatMap(\.self), requiring: lease)
            if summary.isComplete {
                recordCompletedSweep(ownerID: lease.ownerID, endingAt: now)
            }
            await reportQuarantinedLegacyRows()
            return summary
        }

        /// **Plan 07-07 / 07-04's handoff** — the ownerless legacy rows this
        /// build refuses to adopt or delete were a number only the cache knew. A
        /// failed count leaves the previous value alone: "we could not look" is
        /// not "there are none".
        private func reportQuarantinedLegacyRows() async {
            guard let count = try? await cache().quarantinedLegacyRowCount() else { return }
            await MainActor.run {
                HKSyncDiagnostics.shared.recordWithheldCounts(quarantinedLegacyRows: count)
            }
        }

        /// Plan, chunk, transmit, commit — everything after the HealthKit query.
        ///
        /// Split out from ``sync(lookbackDays:)`` so the transmission half can be
        /// driven with synthetic day rows: the query half needs a real
        /// `HKHealthStore` with real authorization, which a unit test does not
        /// have, and the durability rules all live on this side of the split.
        func process(
            _ rows: [HealthKitDailyStatRow],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthKitStatisticsSyncSummary {
            var summary = HealthKitStatisticsSyncSummary.complete

            // Plan first, transmit second. Planning is the only phase that reads
            // the cache, so the batch that goes out is exactly the set of days
            // this account has not already converged.
            var pending: [(action: HealthKitDailyStatsCacheAction, row: HealthKitDailyStatRow)] = []
            for row in rows {
                let action = await cache().plan(ownerUserID: lease.ownerID, for: row)
                if case .skip = action {
                    summary = summary.tallying(action)
                } else {
                    pending.append((action, row))
                }
            }

            for chunk in pending.chunks(of: MeasurementBatchUploader.maxEntriesPerBatch) {
                summary = await transmit(chunk, requiring: lease, into: summary)
            }
            return summary
        }

        /// Sendet einen Chunk und schreibt den Cache genau dann fort, wenn der
        /// Server jede Zeile terminal quittiert hat.
        private func transmit(
            _ chunk: [(action: HealthKitDailyStatsCacheAction, row: HealthKitDailyStatRow)],
            requiring lease: HealthSyncAuthenticatedLease,
            into summary: HealthKitStatisticsSyncSummary
        ) async -> HealthKitStatisticsSyncSummary {
            var summary = summary
            let entries = chunk.map { Self.entry(for: $0.row) }
            do {
                // Check 1 of 3 — before the request.
                try lease.requireCurrent()
                let authLease = try await uploader.captureAuthenticationLeaseIfConfigured()
                _ = try await uploader.upload(entries, requiring: authLease)
                // Check 2 of 3 — before any cache write. An account replacement
                // that lands during the await must not write into the new owner's
                // partition, and must not claim the old owner's day converged.
                try lease.requireCurrent()
            } catch {
                HLLog.healthKit
                    .error("HK-STATS chunk not accepted: \(error.localizedDescription, privacy: .public)")
                let queued = await persistRetry(entries, requiring: lease)
                return summary.tallyingHeld(chunk.count, retryQueued: queued)
            }

            for (action, row) in chunk {
                do {
                    try lease.requireCurrent()
                    try await cache().write(
                        ownerUserID: lease.ownerID,
                        hkIdentifier: row.hkIdentifier,
                        dayKey: row.dayKey,
                        lastPostedValue: row.value,
                        at: clock()
                    )
                } catch {
                    // The server has the value; this device just failed to
                    // remember that. The next sweep re-sends the same stable id
                    // and the server upserts, so nothing is lost — but the sweep
                    // is not complete.
                    HLLog.healthKit
                        .error("HK-STATS cache write failed: \(error.localizedDescription, privacy: .public)")
                    summary = summary.tallyingHeld(1, retryQueued: false)
                    continue
                }
                summary = summary.tallying(action)
                // BF-5 diagnostics: record the action by HK identifier so the
                // operator sees cumulative kinds (Steps etc.) ticking through the
                // stats path. The counter increments AFTER the cache write so the
                // snapshot reflects state actually persisted.
                let identifier = row.hkIdentifier
                let isFirstPost = if case .post = action { true } else { false }
                Task { @MainActor in
                    HKSyncDiagnostics.shared.recordStatsAction(
                        identifier: identifier,
                        posted: isFirstPost ? 1 : 0,
                        reposted: isFirstPost ? 0 : 1
                    )
                }
            }
            return summary
        }

        /// Verbindet eine einzige Action mit dem Server. Internal so dass der
        /// Round-Trip-Test einen Action-Plan direkt ausfuehren kann ohne den
        /// HK-Statistics-Query mit zu mocken — und so dass die Admission ein
        /// verpflichtender Parameter sein kann statt ein optionaler.
        ///
        /// Genau derselbe Pfad wie ein Chunk der Groesse 1; wirft, wenn der
        /// Chunk nicht terminal akzeptiert wurde.
        func execute(
            action: HealthKitDailyStatsCacheAction,
            requiring lease: HealthSyncAuthenticatedLease
        ) async throws {
            guard case .skip = action else {
                let row: HealthKitDailyStatRow = switch action {
                case let .post(row): row
                case let .upsert(row): row
                case .skip: preconditionFailure("unreachable — skip handled above")
                }
                try lease.requireCurrent()
                let authLease = try await uploader.captureAuthenticationLeaseIfConfigured()
                _ = try await uploader.upload([Self.entry(for: row)], requiring: authLease)
                try lease.requireCurrent()
                try await cache().write(
                    ownerUserID: lease.ownerID,
                    hkIdentifier: row.hkIdentifier,
                    dayKey: row.dayKey,
                    lastPostedValue: row.value,
                    at: clock()
                )
                let identifier = row.hkIdentifier
                let isFirstPost = if case .post = action { true } else { false }
                Task { @MainActor in
                    HKSyncDiagnostics.shared.recordStatsAction(
                        identifier: identifier,
                        posted: isFirstPost ? 1 : 0,
                        reposted: isFirstPost ? 0 : 1
                    )
                }
                return
            }
        }

        /// Der Account dieses Passes, oder `nil` wenn keiner admittiert werden
        /// kann. Kein Fallback auf einen ambienten Keychain-Read: ohne Admission
        /// laeuft der Sweep nicht.
        private func admittedLease() -> HealthSyncAuthenticatedLease? {
            guard let admission else { return nil }
            return try? admission()
        }

        // MARK: - Wire helpers

        /// Ein Batch-Entry fuer eine Tageszeile. Die Batch-Route ist der einzige
        /// POST-Pfad, der `externalId` akzeptiert (siehe
        /// `08-locked-contracts.md §2.1` + `createMeasurementSchema` ohne
        /// externalId), und `row.externalId` ist die stabile
        /// `stats:<type>:<day>`-Identitaet, auf der der Server upserted.
        private static func entry(for row: HealthKitDailyStatRow) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: row.hkIdentifier,
                value: row.value,
                unit: row.unit,
                startDate: row.dayStart,
                endDate: row.dayStart,
                externalId: row.externalId,
                externalSourceVersion: nil,
                deviceType: nil
            )
        }

        // Schreibt einen nicht akzeptierten Chunk als owner-gebundene
        // Outbox-Row unter einem **abgeleiteten** Idempotency-Key: ein Prozess,
        // der vor dem Cache-Write stirbt, baut denselben Key neu auf und der
        // Server dedupliziert, statt eine zweite Zeile zu schreiben.
        //
        // Identisch zur Regel, die `HealthSampleConsumption` fuer den
        // Per-Sample-Pfad faehrt — inklusive der stabilen Identitaet aus den
        // sortierten `externalId`s der Zeilen selbst.
    }

    /// Summary-Counters fuer einen Sync-Run. Tests asserten gegen die Felder.
    ///
    /// **Phase 07 / Plan 07-04.** Zwei Aenderungen. `patched` ist entfallen —
    /// der Zaehler zaehlte einen Arm, den Produktion nie erreichte (siehe
    /// ``HealthKitDailyStatsCacheAction``), und ein Feld, das strukturell immer
    /// 0 ist, ist eine falsche Aussage ueber den Pfad. Und ``isComplete`` ist
    /// dazugekommen: ein Sweep ist nur dann vollstaendig, wenn jede geplante
    /// Zeile entweder terminal quittiert **oder** dauerhaft eingereiht wurde.
    /// "Der Sweep lief" und "die Historie ist vollstaendig" sind nicht dasselbe.
    public struct HealthKitStatisticsSyncSummary: Sendable, Equatable {
        public let posted: Int
        public let reposted: Int
        public let skipped: Int
        public let failed: Int
        /// Zeilen, die nicht terminal quittiert wurden, aber als owner-gebundene
        /// Outbox-Row ueberleben. Teilmenge von ``failed``.
        public let retryQueued: Int
        /// `false`, sobald irgendeine geplante Zeile weder terminal noch
        /// dauerhaft eingereiht ist — inklusive eines Passes, der gar nicht
        /// erst laufen durfte (keine Admission).
        public let isComplete: Bool

        public init(
            posted: Int,
            reposted: Int,
            skipped: Int,
            failed: Int,
            retryQueued: Int = 0,
            isComplete: Bool = true
        ) {
            self.posted = posted
            self.reposted = reposted
            self.skipped = skipped
            self.failed = failed
            self.retryQueued = retryQueued
            self.isComplete = isComplete
        }

        /// Ein Pass, der nichts zu tun hatte und alles erledigt hat.
        public static let complete = HealthKitStatisticsSyncSummary(
            posted: 0,
            reposted: 0,
            skipped: 0,
            failed: 0
        )

        /// Der Flag ist aus. Es gibt keine Historie, die dieser Pfad
        /// vervollstaendigen muesste, also ist der Pass in sich vollstaendig.
        public static let disabled = complete

        /// Der Pass durfte nicht laufen (keine Admission). Nichts ist passiert,
        /// und nichts ist erledigt.
        public static let held = HealthKitStatisticsSyncSummary(
            posted: 0,
            reposted: 0,
            skipped: 0,
            failed: 0,
            retryQueued: 0,
            isComplete: false
        )

        public var totalExecuted: Int {
            posted + reposted + skipped + failed
        }

        public func tallying(_ action: HealthKitDailyStatsCacheAction) -> HealthKitStatisticsSyncSummary {
            switch action {
            case .post:
                copy(posted: posted + 1)
            case .upsert:
                copy(reposted: reposted + 1)
            case .skip:
                copy(skipped: skipped + 1)
            }
        }

        /// `count` Zeilen sind nicht terminal quittiert. Der Sweep ist nur dann
        /// weiterhin vollstaendig, wenn sie stattdessen dauerhaft eingereiht
        /// wurden.
        public func tallyingHeld(_ count: Int, retryQueued queued: Bool) -> HealthKitStatisticsSyncSummary {
            HealthKitStatisticsSyncSummary(
                posted: posted,
                reposted: reposted,
                skipped: skipped,
                failed: failed + count,
                retryQueued: retryQueued + (queued ? count : 0),
                isComplete: isComplete && queued
            )
        }

        private func copy(
            posted: Int? = nil,
            reposted: Int? = nil,
            skipped: Int? = nil
        ) -> HealthKitStatisticsSyncSummary {
            HealthKitStatisticsSyncSummary(
                posted: posted ?? self.posted,
                reposted: reposted ?? self.reposted,
                skipped: skipped ?? self.skipped,
                failed: failed,
                retryQueued: retryQueued,
                isComplete: isComplete
            )
        }
    }

    extension HealthKitStatisticsSyncCoordinator: HealthKitDailyStatsSyncing {
        @discardableResult
        public func triggerDailyStatsSync(lookbackDays: Int) async -> Bool {
            let summary = await sync(lookbackDays: lookbackDays)
            let posted = summary.posted
            let reposted = summary.reposted
            let skipped = summary.skipped
            let failed = summary.failed
            let queued = summary.retryQueued
            let complete = summary.isComplete
            HLLog.healthKit
                .info(
                    """
                    HK-STATS sync done — posted=\(posted, privacy: .public) \
                    reposted=\(reposted, privacy: .public) \
                    skipped=\(skipped, privacy: .public) \
                    failed=\(failed, privacy: .public) \
                    retryQueued=\(queued, privacy: .public) \
                    complete=\(complete, privacy: .public)
                    """
                )
            return complete
        }

        /// **v0.12 W8-4** — Sweep der HK-Daily-Stats-Cache-Rows aelter als
        /// `maxAge`. Passthrough auf `HealthKitDailyStatsCache.sweepOlderThan`,
        /// damit der `BackgroundSyncCoordinator`-Cache-Sweep-Hook den
        /// (private) Cache nicht direkt halten muss. Best-effort: Fehler werden
        /// geschluckt + geloggt, der BGTask faellt darauf nicht.
        ///
        /// **Phase 07 / Plan 07-04** — owner-gebunden. Ohne admittierten Account
        /// wird nichts gefegt: ein altersbasierter Sweep unter Account B, der
        /// Account As Rows loescht, ist eine Mutation an fremdem State.
        @discardableResult
        public func sweepCacheOlderThan(_ maxAge: TimeInterval, now: Date = .now) async -> Int {
            guard let lease = admittedLease() else { return 0 }
            do {
                return try await cache().sweepOlderThan(maxAge, ownerUserID: lease.ownerID, now: now)
            } catch {
                HLLog.healthKit.error(
                    "HK-STATS cache sweep failed: \(error.localizedDescription, privacy: .private)"
                )
                return 0
            }
        }

        /// v0.6.2.x bug-c10-ios-direct — see protocol doc. Reads today's
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
    }

#endif
