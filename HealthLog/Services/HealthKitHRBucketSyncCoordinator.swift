import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Platform-agnostic seam for the 10-minute-HR-bucket coordinator. Lives outside
/// the `#if canImport(HealthKit)` block so `AppContainer` can hold a
/// `HealthKitHRBucketSyncing?` slot without the HealthLogCore (HK-free) build
/// breaking.
public protocol HealthKitHRBucketSyncing: AnyObject, Sendable {
    /// One sweep, awaited — the orchestrated `heartRateBuckets` capability.
    /// `lookbackHours` is kept for the call site's budget vocabulary; the
    /// sweep's reach is decided by the per-day ledger (#12), not by it.
    func triggerHRBucketSync(lookbackHours: Int) async

    /// #12 — fire-and-forget sweep request, issued whenever the per-sample
    /// path hands heart rate to the bucket path. Runs in its own task, so a
    /// foreground pass that is cancelled at its deadline cannot take the
    /// sweep down with it; concurrent requests coalesce into one sweep.
    func requestHRBucketSweep()
}

/// The HealthKit read the sweep depends on, behind a seam so the sweep's
/// day logic is testable without a health store.
public protocol HealthKitHRBucketReading: Sendable {
    func bucketRows(from: Date, to: Date) async throws -> [HealthKitHRBucketRow]
}

#if canImport(HealthKit)

    extension HealthKitHRBucketService: HealthKitHRBucketReading {}

    /// Coordinator for the 10-minute-HR-bucket upload path (GH #34, #12).
    ///
    /// **Per-day exclusivity (the invariant):** a bucket is emitted ONLY for a
    /// UTC day that ``HRUploadModeSchedule/mode(at:userId:now:defaults:)`` puts
    /// in the bucket regime AND that the per-sample path has not claimed as a
    /// raw-fallback day (``HRBucketSyncLedger/rawDays``). The per-sample path
    /// drops a sample only for days the bucket path owns (``HRBucketRawGate``),
    /// so no UTC day carries both shapes.
    ///
    /// **No day in neither shape (#12):** the sweep's reach is a set of days,
    /// not a cursor. Every bucket-regime day since the cutover (at most
    /// ``backfillDays`` back) that is not settled is read again: today and
    /// yesterday on every sweep, older days until one successful sweep has
    /// read them in full, and any settled day the per-sample path saw a late
    /// sample for. Only buckets whose accepted fingerprint changed are posted,
    /// one request per day, so the acceptance gate names the day that failed.
    ///
    /// **Gating order** (cheapest first): standalone, share-auth, feature
    /// flag, cutover not reached. Every gate records its name in the ledger
    /// (Sync Diagnostics) and logs it at `.notice`.
    ///
    /// **Completed buckets only:** the query window ends at the start of the
    /// CURRENT UTC 10-minute bucket (exclusive), so the in-progress bucket is
    /// never uploaded until it closes.
    public actor HealthKitHRBucketSyncCoordinator {
        private let service: any HealthKitHRBucketReading
        private let uploader: MeasurementBatchUploader
        private let featureFlags: FeatureFlagsServicing
        private let keychain: KeychainStoring
        private let isStandalone: @Sendable () -> Bool
        private let clock: @Sendable () -> Date
        /// `UserDefaults` is not `Sendable`, so it is injected behind a
        /// `@Sendable` provider closure rather than stored directly — this keeps
        /// the actor's stored state Sendable and lets tests pin an isolated suite
        /// without the init crossing an isolation boundary with a non-Sendable
        /// value. The closure is invoked lazily inside the actor.
        private let defaultsProvider: @Sendable () -> UserDefaults

        /// The sweep in flight, shared by every caller that arrives meanwhile.
        private var running: Task<Int, Never>?
        /// A request arrived while a sweep was running; run once more after it.
        private var rerunRequested = false

        private var defaults: UserDefaults {
            defaultsProvider()
        }

        static let lastBucketDefaultsKeyPrefix = HRBucketCutoverStore.lastBucketDefaultsKeyPrefix

        /// How far back a sweep may reach for a day that never got buckets.
        /// One-time cost after an update from a build that lost days (#12):
        /// at most ~144 rows per day, one request per day.
        static let backfillDays = 90

        /// Days still open for corrections: today and yesterday (UTC). They are
        /// re-read on every sweep; older days settle after one complete read.
        static let openDays = 2

        public init(
            service: any HealthKitHRBucketReading,
            uploader: MeasurementBatchUploader,
            featureFlags: FeatureFlagsServicing,
            keychain: KeychainStoring,
            isStandalone: @escaping @Sendable () -> Bool,
            clock: @escaping @Sendable () -> Date = { Date() },
            defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
        ) {
            self.service = service
            self.uploader = uploader
            self.featureFlags = featureFlags
            self.keychain = keychain
            self.isStandalone = isStandalone
            self.clock = clock
            self.defaultsProvider = defaultsProvider
        }

        /// The UTC days one sweep reads, ascending.
        ///
        /// Bucket-regime days from `max(cutover day, today - backfillDays)`
        /// through today, minus raw-fallback days, minus settled days that are
        /// neither open nor dirty.
        nonisolated static func sweepDays(
            cutover: Date,
            now: Date,
            ledger: HRBucketSyncLedger,
            isBucketDay: (Int) -> Bool
        ) -> [Int] {
            let today = HRBucketSyncLedger.day(of: now)
            let first = max(HRBucketSyncLedger.day(of: cutover), today - backfillDays)
            guard first <= today else { return [] }
            return (first ... today).filter { day in
                guard !ledger.rawDays.contains(day), isBucketDay(day) else { return false }
                let open = day > today - openDays
                return open || ledger.dirtyDays.contains(day) || !ledger.settledDays.contains(day)
            }
        }

        /// Runs one sweep, joining a sweep already in flight. Returns the number
        /// of buckets the server accepted (0 when a gate suppressed the run).
        @discardableResult
        public func sync(lookbackHours _: Int = 48) async -> Int {
            if let running {
                rerunRequested = true
                return await running.value
            }
            var total = 0
            repeat {
                rerunRequested = false
                let task = Task { await self.sweepOnce() }
                running = task
                total += await task.value
                running = nil
            } while rerunRequested
            return total
        }

        // MARK: - One sweep

        private func sweepOnce() async -> Int {
            let startedAt = clock()
            let userID = keychain.getString(forKey: KeychainKey.userID)
            // Gate 1 — standalone: no server in offline mode.
            guard !isStandalone() else {
                return finish(.standalone, userID: userID, startedAt: startedAt)
            }
            // Gate 2 — share-auth: no token, no upload (mirrors the rest of the
            // server-bound HK path; a missing bearer means we are pre-login).
            guard keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false else {
                return finish(.noAuthToken, userID: userID, startedAt: startedAt)
            }
            // Gate 3 — feature flag.
            guard featureFlags.isEnabled(.enableHRBuckets) else {
                return finish(.flagOff, userID: userID, startedAt: startedAt)
            }

            let now = startedAt
            let defaults = defaults
            // Arm + read the cutover boundary (per-day exclusivity anchor).
            let cutover = HRBucketCutoverStore.cutover(userId: userID, now: now, defaults: defaults)
            // End at the start of the CURRENT UTC 10-minute bucket — never
            // upload the in-progress bucket.
            let currentBucketStart = HealthKitHRBucketRow.flooredToUTCTenMinutes(now)
            // Gate 4 — no closed bucket on-or-after the cutover yet.
            guard currentBucketStart > cutover else {
                return finish(.cutoverPending, userID: userID, startedAt: startedAt)
            }

            let ledger = HRBucketSyncLedgerStore.load(userId: userID, defaults: defaults)
            let days = Self.sweepDays(cutover: cutover, now: now, ledger: ledger) { day in
                HRUploadModeSchedule.mode(
                    at: HRBucketSyncLedger.start(ofDay: day),
                    userId: userID,
                    now: now,
                    defaults: defaults
                ) == .buckets
            }
            guard let firstDay = days.first else {
                return finish(.upToDate, userID: userID, startedAt: startedAt)
            }

            let rows: [HealthKitHRBucketRow]
            do {
                let from = max(HRBucketSyncLedger.start(ofDay: firstDay), cutover)
                rows = try await service.bucketRows(from: from, to: currentBucketStart)
            } catch {
                let gate: HRBucketGate = Self.isHealthDataLocked(error) ? .healthDataLocked : .queryFailed
                return finish(gate, userID: userID, startedAt: startedAt)
            }

            let byDay = Dictionary(grouping: rows.filter { $0.bucketStartUTC >= cutover && $0.bucketStartUTC < currentBucketStart }) {
                HRBucketSyncLedger.day(of: $0.bucketStartUTC)
            }
            var progress = SweepProgress()
            for day in days {
                await sweep(day: day, rows: byDay[day] ?? [], userID: userID, now: now, progress: &progress)
            }
            return finish(progress, userID: userID, startedAt: startedAt, dayCount: days.count)
        }

        /// What one sweep achieved across its days.
        private struct SweepProgress {
            var accepted = 0
            var failure: HRBucketGate?
        }

        /// Posts one day's new or changed buckets and settles the day when it is
        /// closed and fully read.
        private func sweep(
            day: Int,
            rows: [HealthKitHRBucketRow],
            userID: String?,
            now: Date,
            progress: inout SweepProgress
        ) async {
            let defaults = defaults
            let ledger = HRBucketSyncLedgerStore.load(userId: userID, defaults: defaults)
            // The per-sample path may have claimed the day since the sweep began.
            guard !ledger.rawDays.contains(day) else { return }
            let known = ledger.accepted[day] ?? [:]
            let changed = rows.filter { known[HRBucketSyncLedger.slot(of: $0.bucketStartUTC)] != HRBucketSyncLedger.fingerprint($0) }
            if !changed.isEmpty {
                do {
                    try await uploader.upload(changed.map(Self.entry(for:)))
                } catch {
                    let gate: HRBucketGate = Self.isTransient(error) ? .uploadDeferred : .uploadFailed
                    if progress.failure != .uploadFailed { progress.failure = gate }
                    // Gate name and the error's type only: a message with any
                    // `.private` part is redacted whole on a tester's device.
                    let errorType = String(describing: type(of: error))
                    HLLog.healthKit
                        .error("HR-BUCKET upload failed — gate=\(gate.rawValue, privacy: .public) error=\(errorType, privacy: .public)")
                    return
                }
                progress.accepted += changed.count
            }
            let today = HRBucketSyncLedger.day(of: now)
            HRBucketSyncLedgerStore.update(userId: userID, defaults: defaults, now: now) { ledger in
                if !changed.isEmpty {
                    ledger.bucketDays.insert(day)
                    var fingerprints = ledger.accepted[day] ?? [:]
                    for row in changed {
                        fingerprints[HRBucketSyncLedger.slot(of: row.bucketStartUTC)] = HRBucketSyncLedger.fingerprint(row)
                    }
                    ledger.accepted[day] = fingerprints
                    if let newest = changed.map(\.bucketStartUTC).max(),
                       newest > (ledger.lastAcceptedBucket ?? .distantPast)
                    {
                        ledger.lastAcceptedBucket = newest
                    }
                }
                if day <= today - Self.openDays {
                    ledger.settledDays.insert(day)
                    ledger.dirtyDays.remove(day)
                    ledger.accepted[day] = nil
                }
            }
            if !changed.isEmpty, let newest = changed.map(\.bucketStartUTC).max() {
                // Kept for ``HRBucketCutoverStore/cutover(userId:now:defaults:)``,
                // which re-arms a logged-out account on the cursor's day (A7).
                let key = HRBucketCutoverStore.lastBucketKey(for: userID)
                if newest > (defaults.object(forKey: key) as? Date ?? .distantPast) {
                    defaults.set(newest, forKey: key)
                }
            }
        }

        // MARK: - Outcome

        private func finish(_ gate: HRBucketGate, userID: String?, startedAt: Date) -> Int {
            HRBucketSyncLedgerStore.update(userId: userID, defaults: defaults, now: startedAt) { ledger in
                ledger.record(gate, at: startedAt)
                if gate.isSuccess {
                    ledger.lastSuccessAt = startedAt
                    if let owed = ledger.owedSince, owed <= startedAt { ledger.owedSince = nil }
                } else if gate == .queryFailed {
                    ledger.lastFailureAt = startedAt
                }
            }
            // A gate name — a fixed enum case. `.public` is correct here.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.notice("HR-BUCKET sweep — gate=\(gate.rawValue, privacy: .public) accepted=0")
            return 0
        }

        private func finish(_ progress: SweepProgress, userID: String?, startedAt: Date, dayCount: Int) -> Int {
            let gate = progress.failure ?? (progress.accepted > 0 ? .uploaded : .upToDate)
            HRBucketSyncLedgerStore.update(userId: userID, defaults: defaults, now: startedAt) { ledger in
                ledger.record(gate, at: startedAt, count: progress.accepted)
                switch gate {
                case .uploadFailed:
                    ledger.lastFailureAt = startedAt
                case .uploadDeferred:
                    break
                default:
                    ledger.lastSuccessAt = startedAt
                    if let owed = ledger.owedSince, owed <= startedAt { ledger.owedSince = nil }
                }
            }
            // Gate name and counts only — no value, date or account.
            HLLog.healthKit
                .notice(
                    "HR-BUCKET sweep — gate=\(gate.rawValue, privacy: .public) accepted=\(progress.accepted, privacy: .public) days=\(dayCount, privacy: .public)"
                )
            return progress.accepted
        }

        // MARK: - Helpers

        private static func entry(for row: HealthKitHRBucketRow) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: HealthKitHRBucketRow.hkIdentifier,
                value: row.averageBpm,
                valueMin: row.minBpm,
                valueMax: row.maxBpm,
                unit: HealthKitHRBucketRow.wireUnit,
                // startDate = bucket start; endDate = bucket end → measuredAt.
                startDate: row.bucketStartUTC,
                endDate: row.bucketEndUTC,
                externalId: row.externalId,
                externalSourceVersion: nil,
                deviceType: nil
            )
        }

        /// HealthKit answers a query on a locked device with
        /// `errorDatabaseInaccessible`. That is not the path failing; the next
        /// unlocked sweep reads the same days.
        nonisolated static func isHealthDataLocked(_ error: Error) -> Bool {
            (error as? HKError)?.code == .errorDatabaseInaccessible
        }

        /// Conditions the next sweep is expected to clear on its own. They do
        /// not mark the path failed; a path that stays stuck on them is caught
        /// by the starvation limit instead.
        nonisolated static func isTransient(_ error: Error) -> Bool {
            if error is CancellationError || error is URLError || error is BatchBackoffError {
                return true
            }
            if let error = error as? MeasurementUploadAuthenticationLease.ValidationError {
                return error == .staleAuthentication
            }
            if let error = error as? HLError {
                if case .canceled = error { return true }
                return error.isRetriable
            }
            return false
        }

        static func lastBucketKey(for userID: String?) -> String {
            HRBucketCutoverStore.lastBucketKey(for: userID)
        }
    }

    extension HealthKitHRBucketSyncCoordinator: HealthKitHRBucketSyncing {
        public func triggerHRBucketSync(lookbackHours: Int) async {
            _ = await sync(lookbackHours: lookbackHours)
        }

        public nonisolated func requestHRBucketSweep() {
            Task { await self.sync() }
        }
    }

#endif
