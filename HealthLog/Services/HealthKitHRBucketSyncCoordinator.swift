import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Platform-agnostic seam for the 10-minute-HR-bucket coordinator. Lives outside
/// the `#if canImport(HealthKit)` block so `AppContainer` can hold a
/// `HealthKitHRBucketSyncing?` slot without the HealthLogCore (HK-free) build
/// breaking. Single surface: `triggerHRBucketSync(lookbackHours:)`.
public protocol HealthKitHRBucketSyncing: AnyObject, Sendable {
    /// Upload the completed 10-minute-HR `stats:` buckets in the last
    /// `lookbackHours` window (clamped to on-or-after the per-User cutover).
    /// Fire-and-forget — counters land in the log; the headline guarantee
    /// (per-day exclusivity) is enforced upstream by the cutover gate.
    func triggerHRBucketSync(lookbackHours: Int) async
}

#if canImport(HealthKit)

    /// Coordinator for the 10-minute-HR-bucket upload path (GH #34).
    ///
    /// **Per-day exclusivity (the invariant):** a bucket is emitted ONLY when
    /// ``HRUploadModeSchedule/mode(at:userId:now:defaults:)`` says its UTC start
    /// uploads as buckets — the armed `hrBucketCutoverDayUTC` boundary
    /// (``HRBucketCutoverStore``) plus every operator switch layered on top. The
    /// per-sample HR path drops exactly the samples that same function marks
    /// `.buckets`. Both read one function whose steps all fall on UTC midnights,
    /// so no UTC day can ever produce both raw per-sample HR rows AND `stats:`
    /// bucket rows — the server's nightly PULSE rollup never double-counts.
    ///
    /// **Gating order** (cheapest first): standalone → no upload; share-auth
    /// missing → no upload; feature-flag OFF → no upload.
    ///
    /// **Completed buckets only:** the query window ends at the start of the
    /// CURRENT UTC 10-minute bucket (exclusive), so the in-progress bucket is
    /// never uploaded until it closes. Re-uploading a just-closed bucket on the
    /// next sweep is safe — the stable externalId overwrites the server row
    /// (`updated`).
    ///
    /// **Incremental:** the max uploaded bucket is persisted per-User; the next
    /// sweep re-queries from `max(cutover, lastBucket)` so a long-running app does
    /// not re-walk the whole window each time. The most-recent closed bucket is
    /// always re-uploaded (overwrite) to absorb late Watch sync corrections.
    public actor HealthKitHRBucketSyncCoordinator {
        private let service: HealthKitHRBucketService
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

        private var defaults: UserDefaults {
            defaultsProvider()
        }

        static let lastBucketDefaultsKeyPrefix = HRBucketCutoverStore.lastBucketDefaultsKeyPrefix

        /// Build 273 (A6) — how far a catch-up from the persisted cursor may
        /// reach back. Bounds the HealthKit query and the upload after a long
        /// dormancy; the server dedups on `externalId`, so the overlap is free.
        static let maxCatchUpSeconds: TimeInterval = 30 * 24 * 3600

        /// The window's start. With a cursor: one bucket before it (a late
        /// correction overwrites the newest uploaded bucket), never further back
        /// than ``maxCatchUpSeconds`` — and NOT floored at `now - lookbackHours`,
        /// which left every hour between the cursor and that floor in neither
        /// shape on the server after a dormancy longer than the lookback
        /// (`heartRateBuckets` is not an incremental partition, and the raw path
        /// drops HR once in bucket mode). Without a cursor: the lookback, as on
        /// the first run. The cutover is always a floor.
        nonisolated static func windowStart(
            cutover: Date,
            now: Date,
            lookbackHours: Int,
            lastUploadedBucket: Date?
        ) -> Date {
            let start: Date
            if let lastUploadedBucket {
                let reincluded = lastUploadedBucket.addingTimeInterval(-HealthKitHRBucketRow.bucketSeconds)
                let bound = HealthKitHRBucketRow.flooredToUTCTenMinutes(now.addingTimeInterval(-maxCatchUpSeconds))
                start = max(reincluded, bound)
            } else {
                let lookbackStart = now.addingTimeInterval(-Double(lookbackHours) * 3600)
                start = HealthKitHRBucketRow.flooredToUTCTenMinutes(lookbackStart)
            }
            return max(start, cutover)
        }

        public init(
            service: HealthKitHRBucketService,
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

        /// Runs one sweep. Returns the number of buckets actually uploaded (0 when
        /// any gate suppresses the run). Tests assert against the count + the
        /// captured payloads.
        @discardableResult
        public func sync(lookbackHours: Int = 48) async -> Int {
            // Gate 1 — standalone: no server in offline mode.
            guard !isStandalone() else {
                HLLog.healthKit.debug("HR-BUCKET sync skipped — standalone mode")
                return 0
            }
            // Gate 2 — share-auth: no token, no upload (mirrors the rest of the
            // server-bound HK path; a missing bearer means we are pre-login).
            guard keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false else {
                HLLog.healthKit.debug("HR-BUCKET sync skipped — no auth token")
                return 0
            }
            // Gate 3 — feature flag.
            guard featureFlags.isEnabled(.enableHRBuckets) else {
                HLLog.healthKit.debug("HR-BUCKET sync skipped — enableHRBuckets OFF")
                return 0
            }

            let userID = keychain.getString(forKey: KeychainKey.userID)
            let now = clock()
            // Arm + read the cutover boundary (per-day exclusivity anchor).
            let cutover = HRBucketCutoverStore.cutover(userId: userID, now: now, defaults: defaults)
            // End at the start of the CURRENT UTC 10-minute bucket — never upload
            // the in-progress bucket.
            let currentBucketStart = HealthKitHRBucketRow.flooredToUTCTenMinutes(now)

            // Window start — see `windowStart(cutover:now:lookbackHours:lastUploadedBucket:)`.
            let windowStart = Self.windowStart(
                cutover: cutover,
                now: now,
                lookbackHours: lookbackHours,
                lastUploadedBucket: persistedLastBucket(userID: userID)
            )

            guard currentBucketStart > windowStart else {
                // No closed bucket on-or-after the cutover yet (e.g. cutover is in
                // the future, or app launched within the same bucket).
                return 0
            }

            let rows: [HealthKitHRBucketRow]
            do {
                rows = try await service.bucketRows(from: windowStart, to: currentBucketStart)
            } catch {
                HLLog.healthKit.error(
                    "HR-BUCKET query failed: \(error.localizedDescription, privacy: .private)"
                )
                return 0
            }

            // The exclusivity predicate, applied per bucket. The armed cutover is
            // the hard floor (nothing before it is ever bucketed); on top of it
            // `HRUploadModeSchedule` carries the operator's raw/bucket switches,
            // so a stretch of days the operator put back on the per-sample path
            // produces NO buckets even though it lies inside the query window.
            // The per-sample gate in `HealthLogStandard` reads the same function,
            // which is what makes "never both on one UTC day" structural rather
            // than a coincidence of two filters agreeing.
            let eligible = rows.filter { row in
                row.bucketStartUTC >= cutover
                    && row.bucketStartUTC < currentBucketStart
                    && HRUploadModeSchedule.mode(
                        at: row.bucketStartUTC,
                        userId: userID,
                        now: now,
                        defaults: defaults
                    ) == .buckets
            }
            guard !eligible.isEmpty else { return 0 }

            let entries = eligible.map { row in
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

            do {
                try await uploader.upload(entries)
            } catch {
                HLLog.healthKit.error(
                    "HR-BUCKET upload failed: \(error.localizedDescription, privacy: .private)"
                )
                return 0
            }

            // Advance the incremental cursor to the latest uploaded bucket.
            if let maxBucket = eligible.map(\.bucketStartUTC).max() {
                persistLastBucket(maxBucket, userID: userID)
            }
            let count = entries.count
            HLLog.healthKit
                .info(
                    "HR-BUCKET sync done — uploaded=\(count, privacy: .public) 10-min buckets"
                )
            return count
        }

        // MARK: - Incremental cursor

        private func persistedLastBucket(userID: String?) -> Date? {
            defaults.object(forKey: Self.lastBucketKey(for: userID)) as? Date
        }

        private func persistLastBucket(_ bucket: Date, userID: String?) {
            defaults.set(bucket, forKey: Self.lastBucketKey(for: userID))
        }

        static func lastBucketKey(for userID: String?) -> String {
            HRBucketCutoverStore.lastBucketKey(for: userID)
        }
    }

    extension HealthKitHRBucketSyncCoordinator: HealthKitHRBucketSyncing {
        public func triggerHRBucketSync(lookbackHours: Int) async {
            _ = await sync(lookbackHours: lookbackHours)
        }
    }

#endif
