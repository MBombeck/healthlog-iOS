import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Operational provenance only. No user, workout, or request identifiers are
/// allowed into the direct-workout diagnostic context.
public enum WorkoutSyncSource: String, Codable, Sendable, Equatable, CaseIterable {
    case registration
    case observer
    case processing
    case appRefresh
    case push
    case foreground
    case manual
}

enum WorkoutSyncDiagnosticContext {
    @TaskLocal static var source: WorkoutSyncSource?
}

/// Per-kind sync-health counters surfaced in Settings → Apple Health →
/// "Sync-Diagnose". Built for v0.5.4 BF-5 ("Apple Health lokale Daten werden
/// nicht dargestellt") so the operator — and future debug sessions — can see
/// at a glance which `MetricKind` is actually flowing.
///
/// **Design (deliberately tiny):**
/// - One counter struct per HK identifier, four monotonic fields.
/// - Backed by an `@MainActor`-isolated `@Observable` store so a SwiftUI view
///   can read the snapshot without bouncing through an actor `await`.
/// - No persistence — the counters live for the current process. Diagnostic
///   tool, not analytics. A re-launch starts from zero and that's correct:
///   the question "is HK syncing right now" has a session-scope answer.
/// - Sink-pattern: callers hand a `Snapshot` delta in via `record(...)`. The
///   store accumulates. Both `HealthKitService.handleNewSamples` (reads +
///   uploads) and `HealthKitStatisticsSyncCoordinator.execute` (HK-STATS path)
///   plug into the same surface.
///
/// **Why not just os_signpost / Instruments?** The operator can't read
/// signposts on their device. The surface needs to be human-readable inline
/// in Settings → Apple Health, so a counter-store is the right shape.
@MainActor
@Observable
public final class HKSyncDiagnostics {
    public static let shared = HKSyncDiagnostics()

    /// Per-HK-identifier counters. Keyed by the raw HKQuantityTypeIdentifier
    /// / HKCategoryTypeIdentifier string (`"HKQuantityTypeIdentifierStepCount"`
    /// etc.) so the diagnostics surface can render every kind exactly the way
    /// HK + the server know it. Empty dict = nothing observed yet.
    public private(set) var byIdentifier: [String: KindStats] = [:]

    /// Timestamp of the most recent `record(...)` call across all kinds —
    /// surfaces the "last activity" line in the UI without scanning the dict.
    /// Useful operator-tell: if it's > 1h ago, observation is asleep.
    public private(set) var lastActivityAt: Date?

    /// **W-B182** — last time `SpeziCollectionTrigger.trigger` actively pulled
    /// the manual collectors, plus its source (background / foreground /
    /// manual). Persisted (anchors-class data, doctrine-allowed) so the
    /// diagnostics surface can distinguish "armed, nothing new" (healthy: a
    /// recent trigger but no fresh observation) from "never armed" (broken: no
    /// trigger ever recorded) across relaunches.
    public private(set) var lastCollectionTriggerAt: Date?
    public private(set) var lastCollectionTriggerSource: String?

    /// **W-B182** — last successful per-identifier observation, persisted across
    /// relaunches so the surface survives the cold-launch reset that wiped the
    /// operator's evidence before. Memory counters above stay session-scope
    /// (monotonic "this session" semantics); this dict carries only the
    /// last-success timestamp per identifier for the cross-launch staleness call.
    public private(set) var persistedLastObservation: [String: Date] = [:]

    /// **#66 P0.1 (Baustein 4) — honest background-wake evidence.** Each of the
    /// three wake channels that pull HealthKit + drain the outbox records its
    /// last successful entry here, plus the last background-context observer
    /// delivery on the vital-sign path. All four are persisted (anchors-class:
    /// bare timestamps, no PII / values) so the Sync-Diagnose surface can tell
    /// the operator which channels are actually firing across relaunches — the
    /// core "reaches the server only in the foreground" question from #66.
    public private(set) var lastProcessingWakeAt: Date?
    public private(set) var lastAppRefreshWakeAt: Date?
    public private(set) var lastPushWakeAt: Date?
    public private(set) var lastBackgroundObservationAt: Date?

    /// Persisted workout-delivery evidence containing only timestamps, enums,
    /// and aggregate counts. Health values, identifiers, and payload text are
    /// structurally absent from this type.
    public private(set) var workout = WorkoutSnapshot()

    /// **Phase 07 / plan 07-07** — what the last orchestrated pass did, plus the
    /// two withheld-item counts that had no operator surface before.
    ///
    /// Persisted for the same reason the wake timestamps are: the questions
    /// "did anything refuse" and "how much is this account still owed" have
    /// cross-launch answers, and a cold-launch reset was exactly what hid them.
    public internal(set) var healthSync = HealthSyncSnapshot()

    /// **#66 P0.1** — the wake channels the diagnostics surface distinguishes.
    /// `observer` is a background-context vital-sign delivery (the six
    /// `continueInBackground: true` collectors); the other three are the
    /// explicit wake triggers.
    public enum WakeKind: String, Sendable {
        case processing
        case appRefresh
        case push
        case observer
    }

    public enum WorkoutRegistrationState: String, Codable, Sendable, Equatable {
        case notAttempted
        case attempted
        case succeeded
        case failed
    }

    public enum WorkoutFailureClass: String, Codable, Sendable, Equatable {
        case registration
        case healthKitQuery
        case transport
        case serverRejected
        case persistence
        case cancelled
        case unknown
    }

    public enum WorkoutBackfillState: String, Codable, Sendable, Equatable {
        case idle
        case running
        case progressed
        case finished
        case authorizationPending
        case failed
        case serverUnsupported
    }

    public struct WorkoutSnapshot: Codable, Sendable, Equatable {
        public var registrationState: WorkoutRegistrationState = .notAttempted
        public var lastRegistrationAttemptAt: Date?
        public var lastRegistrationSucceededAt: Date?
        public var observerCallbacksTotal = 0
        public var lastObserverAt: Date?
        public var lastAttemptedAt: Date?
        public var lastCompletedUsefulAt: Date?
        public var lastSource: WorkoutSyncSource?
        public var fetchedTotal = 0
        public var mappedTotal = 0
        public var sentTotal = 0
        public var acceptedTotal = 0
        public var skippedTotal = 0
        public var lastFailure: WorkoutFailureClass?
        public var backfillState: WorkoutBackfillState = .idle
        public var backfillEnrichedTotal = 0
        public var lastBackfillAt: Date?

        public init() {}
    }

    /// UserDefaults persistence (anchors-class — timestamps + source string, no
    /// PII / values). Keys are app-global, not per-user: the diagnostics surface
    /// is a debug heartbeat, and `reset()` (logout) clears them.
    private let defaults: UserDefaults
    private static let triggerAtKey = "hl.hksync.lastCollectionTriggerAt"
    private static let triggerSourceKey = "hl.hksync.lastCollectionTriggerSource"
    private static let lastObservationKey = "hl.hksync.persistedLastObservation"
    private static let processingWakeKey = "hl.hksync.lastProcessingWakeAt"
    private static let appRefreshWakeKey = "hl.hksync.lastAppRefreshWakeAt"
    private static let pushWakeKey = "hl.hksync.lastPushWakeAt"
    private static let observerWakeKey = "hl.hksync.lastBackgroundObservationAt"
    private static let workoutKey = "hl.hksync.workout.delivery.v1"
    private static let healthSyncKey = "hl.hksync.pass.v1"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTrigger = defaults.double(forKey: Self.triggerAtKey)
        if storedTrigger > 0 {
            lastCollectionTriggerAt = Date(timeIntervalSince1970: storedTrigger)
        }
        lastCollectionTriggerSource = defaults.string(forKey: Self.triggerSourceKey)
        if let raw = defaults.dictionary(forKey: Self.lastObservationKey) as? [String: Double] {
            persistedLastObservation = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        lastProcessingWakeAt = Self.loadDate(defaults, Self.processingWakeKey)
        lastAppRefreshWakeAt = Self.loadDate(defaults, Self.appRefreshWakeKey)
        lastPushWakeAt = Self.loadDate(defaults, Self.pushWakeKey)
        lastBackgroundObservationAt = Self.loadDate(defaults, Self.observerWakeKey)
        if let data = defaults.data(forKey: Self.workoutKey),
           let decoded = try? JSONDecoder().decode(WorkoutSnapshot.self, from: data)
        {
            workout = decoded
        }
        if let data = defaults.data(forKey: Self.healthSyncKey),
           let decoded = try? JSONDecoder().decode(HealthSyncSnapshot.self, from: data)
        {
            healthSync = decoded
        }
    }

    /// Read a persisted `timeIntervalSince1970` back into a `Date?`, treating a
    /// missing / zero key as "never happened".
    private static func loadDate(_ defaults: UserDefaults, _ key: String) -> Date? {
        let stored = defaults.double(forKey: key)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// Reset all counters. Wired into `AuthStore.handleLogout` so the next
    /// user doesn't inherit the previous user's HK-sync history. Clears the
    /// persisted timestamps too (the next user starts from a clean slate).
    public func reset() {
        byIdentifier.removeAll()
        lastActivityAt = nil
        lastCollectionTriggerAt = nil
        lastCollectionTriggerSource = nil
        persistedLastObservation.removeAll()
        lastProcessingWakeAt = nil
        lastAppRefreshWakeAt = nil
        lastPushWakeAt = nil
        lastBackgroundObservationAt = nil
        workout = WorkoutSnapshot()
        healthSync = HealthSyncSnapshot()
        defaults.removeObject(forKey: Self.healthSyncKey)
        defaults.removeObject(forKey: Self.triggerAtKey)
        defaults.removeObject(forKey: Self.triggerSourceKey)
        defaults.removeObject(forKey: Self.lastObservationKey)
        defaults.removeObject(forKey: Self.processingWakeKey)
        defaults.removeObject(forKey: Self.appRefreshWakeKey)
        defaults.removeObject(forKey: Self.pushWakeKey)
        defaults.removeObject(forKey: Self.observerWakeKey)
        defaults.removeObject(forKey: Self.workoutKey)
    }

    /// **#66 P0.1 (Baustein 4)** — record a background-wake heartbeat for one of
    /// the three wake channels (BGProcessing / BGAppRefresh / silent push) or a
    /// background-context vital-sign observer delivery. Persisted so the
    /// Sync-Diagnose surface can show which channels are alive across relaunches.
    public func recordWake(_ kind: WakeKind, at date: Date = Date()) {
        switch kind {
        case .processing:
            lastProcessingWakeAt = date
            defaults.set(date.timeIntervalSince1970, forKey: Self.processingWakeKey)
        case .appRefresh:
            lastAppRefreshWakeAt = date
            defaults.set(date.timeIntervalSince1970, forKey: Self.appRefreshWakeKey)
        case .push:
            lastPushWakeAt = date
            defaults.set(date.timeIntervalSince1970, forKey: Self.pushWakeKey)
        case .observer:
            lastBackgroundObservationAt = date
            defaults.set(date.timeIntervalSince1970, forKey: Self.observerWakeKey)
        }
    }

    /// **W-B182** — record an active collection-trigger heartbeat. Called from
    /// `SpeziCollectionTrigger.trigger` on every BG / foreground / manual pull.
    /// Persisted so "never armed" vs "armed, idle" survives relaunch.
    public func recordCollectionTrigger(source: String, at date: Date = Date()) {
        lastCollectionTriggerAt = date
        lastCollectionTriggerSource = source
        defaults.set(date.timeIntervalSince1970, forKey: Self.triggerAtKey)
        defaults.set(source, forKey: Self.triggerSourceKey)
    }

    // MARK: - Workout delivery diagnostics (Phase 1 / Plan 04)

    public func recordWorkoutRegistration(
        _ state: WorkoutRegistrationState,
        at date: Date = Date()
    ) {
        workout.registrationState = state
        workout.lastRegistrationAttemptAt = date
        if state == .succeeded {
            workout.lastRegistrationSucceededAt = date
            workout.lastFailure = nil
        } else if state == .failed {
            workout.lastFailure = .registration
        }
        persistWorkout()
    }

    public func recordWorkoutObserverCallback(at date: Date = Date()) {
        workout.observerCallbacksTotal += 1
        workout.lastObserverAt = date
        persistWorkout()
    }

    /// An attempt starts before the anchored query. It is not proof of server
    /// work; only a response with accepted entries advances useful completion.
    public func recordWorkoutAttempt(source: WorkoutSyncSource, at date: Date = Date()) {
        workout.lastAttemptedAt = date
        workout.lastSource = source
        workout.lastFailure = nil
        persistWorkout()
    }

    public func recordWorkoutFetch(fetched: Int, mapped: Int) {
        workout.fetchedTotal += max(0, fetched)
        workout.mappedTotal += max(0, mapped)
        persistWorkout()
    }

    public func recordWorkoutSend(count: Int) {
        workout.sentTotal += max(0, count)
        persistWorkout()
    }

    public func recordWorkoutResponse(
        accepted: Int,
        skipped: Int,
        completeAcceptance: Bool,
        at date: Date = Date()
    ) {
        let accepted = max(0, accepted)
        let skipped = max(0, skipped)
        workout.acceptedTotal += accepted
        workout.skippedTotal += skipped
        if completeAcceptance, accepted > 0 {
            workout.lastCompletedUsefulAt = date
            workout.lastFailure = nil
        } else if skipped > 0 || !completeAcceptance {
            workout.lastFailure = .serverRejected
        }
        persistWorkout()
    }

    public func recordWorkoutFailure(_ failure: WorkoutFailureClass) {
        workout.lastFailure = failure
        persistWorkout()
    }

    public func recordWorkoutBackfill(_ state: WorkoutBackfillState, enriched: Int = 0) {
        workout.backfillState = state
        workout.backfillEnrichedTotal += max(0, enriched)
        workout.lastBackfillAt = Date()
        persistWorkout()
    }

    private func persistWorkout() {
        guard let data = try? JSONEncoder().encode(workout) else { return }
        defaults.set(data, forKey: Self.workoutKey)
    }

    /// Internal so the Phase-07 recorders in `HKSyncDiagnostics+HealthSync.swift`
    /// can stamp the shared "last activity" heartbeat.
    func noteActivity(at date: Date) {
        lastActivityAt = date
    }

    /// Internal so the Phase-07 recorders in `HKSyncDiagnostics+HealthSync.swift`
    /// can persist through the same `UserDefaults` handle.
    func persistHealthSync() {
        guard let data = try? JSONEncoder().encode(healthSync) else { return }
        defaults.set(data, forKey: Self.healthSyncKey)
    }

    #if DEBUG
        /// Test-only factory — builds an isolated instance backed by a custom
        /// `UserDefaults` suite so the persistence round-trip can be exercised
        /// without touching `.standard` or the `shared` singleton.
        @MainActor
        static func makeForTesting(defaults: UserDefaults) -> HKSyncDiagnostics {
            HKSyncDiagnostics(defaults: defaults)
        }
    #endif

    /// Record an HK-observation event for one identifier.
    ///
    /// - Parameter identifier: raw HKType identifier string. Use the same
    ///   value the wire converter + Apple emit.
    /// - Parameter samplesRead: number of new samples handed back by
    ///   `HKAnchoredObjectQuery` for this identifier (FOREIGN samples; we
    ///   already filter our own writes upstream). Pass `0` if the
    ///   observation fired but had nothing new — we still bump
    ///   `lastObservationAt` so the operator can see the heartbeat.
    /// - Parameter samplesUploaded: subset of `samplesRead` that actually
    ///   went up the batch route as a non-skipped entry (`inserted` +
    ///   `duplicate`; explicit `skipped` rows DO NOT count — they are an
    ///   "unknown to server" signal we want visible).
    public func recordObservation(
        identifier: String,
        samplesRead: Int,
        samplesUploaded: Int,
        anchorAdvanced: Bool,
        at date: Date = Date()
    ) {
        var stats = byIdentifier[identifier] ?? KindStats(identifier: identifier)
        stats.samplesReadTotal += samplesRead
        stats.samplesUploadedTotal += samplesUploaded
        stats.lastObservationAt = date
        if anchorAdvanced {
            stats.lastAnchorAdvancedAt = date
        }
        byIdentifier[identifier] = stats
        lastActivityAt = date
        // W-B182 — persist last-observation timestamp so the cross-launch
        // staleness call survives the cold-launch counter reset.
        persistLastObservation(identifier: identifier, at: date)
    }

    /// **W-B182** — persist the last-observation timestamp for one identifier
    /// (anchors-class data: a timestamp, no PII / values).
    private func persistLastObservation(identifier: String, at date: Date) {
        persistedLastObservation[identifier] = date
        var raw = defaults.dictionary(forKey: Self.lastObservationKey) as? [String: Double] ?? [:]
        raw[identifier] = date.timeIntervalSince1970
        defaults.set(raw, forKey: Self.lastObservationKey)
    }

    /// Record an HK-STATS first post or later upsert. Separate from the
    /// per-sample path because cumulative kinds (Steps / Active Energy /
    /// Flights / Distance / Time-in-Daylight) flow over
    /// `HealthKitStatisticsSyncCoord`, not the per-sample batch route — the
    /// operator surface deserves a signal that this OTHER path is alive too.
    ///
    /// **Phase 07 / Plan 07-04** — the `patched` counter is gone with the PATCH
    /// arm it counted; that arm required a server row id the stats path never
    /// obtained, so it was unreachable in production.
    public func recordStatsAction(
        identifier: String,
        posted: Int,
        reposted: Int,
        at date: Date = Date()
    ) {
        var stats = byIdentifier[identifier] ?? KindStats(identifier: identifier)
        stats.statsPostedTotal += posted
        stats.statsRepostedTotal += reposted
        stats.lastStatsActionAt = date
        byIdentifier[identifier] = stats
        lastActivityAt = date
    }

    /// Convenience for the UI: snapshot keyed by `MetricKind` (vs raw HK
    /// identifier). Multiple HK identifiers can map to a single domain kind
    /// (BP-sys + BP-dia both feed `.bloodPressure`); the rollup sums.
    public func snapshotByKind() -> [MetricKind: KindStats] {
        var rolled: [MetricKind: KindStats] = [:]
        for (identifier, stats) in byIdentifier {
            guard let kind = Self.metricKind(for: identifier) else { continue }
            if let existing = rolled[kind] {
                rolled[kind] = existing.merging(stats)
            } else {
                // Renormalise the identifier on the merged entry to the
                // canonical kind raw value so the UI doesn't show
                // "HKQuantityTypeIdentifierBloodPressureSystolic" for BP.
                var copy = stats
                copy.identifier = kind.rawValue
                rolled[kind] = copy
            }
        }
        return rolled
    }

    /// Reverse-map an HK identifier to a `MetricKind`. Mirrors the table in
    /// `HealthKitWireConverter.preferredUnit` plus the server-side
    /// `apple-health-mapping.ts`. Stays in lockstep with the read-types set
    /// in `HealthKitService.defaultReadTypes` — if you add a new HK identifier
    /// there, add a row here too or the diagnostics view drops it.
    ///
    /// Dictionary-backed (vs `switch`) to keep cyclomatic complexity under
    /// the 12-branch SwiftLint threshold.
    public nonisolated static func metricKind(for identifier: String) -> MetricKind? {
        identifierToKind[identifier]
    }

    /// Reverse-map table. Built once at class-load and read everywhere; HK
    /// identifiers are stable string constants so this is cheaper than the
    /// switch alternative both on disk and in CPU.
    public nonisolated static let identifierToKind: [String: MetricKind] = {
        #if canImport(HealthKit)
            var map: [String: MetricKind] = [
                HKQuantityTypeIdentifier.bodyMass.rawValue: .weight,
                HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue: .bloodPressure,
                HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue: .bloodPressure,
                HKQuantityTypeIdentifier.heartRate.rawValue: .pulse,
                HKQuantityTypeIdentifier.bloodGlucose.rawValue: .glucose,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: .bodyFat,
                HKQuantityTypeIdentifier.bodyTemperature.rawValue: .bodyTemperature,
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue: .spo2,
                HKCategoryTypeIdentifier.sleepAnalysis.rawValue: .sleep,
                HKQuantityTypeIdentifier.stepCount.rawValue: .steps,
                HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: .activeEnergy,
                HKQuantityTypeIdentifier.flightsClimbed.rawValue: .flightsClimbed,
                HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: .distanceWalkingRunning,
                // Time in Daylight ships on iOS 17+; the raw identifier string is
                // stable across SDK levels even where the symbol is unavailable,
                // so we reference it directly (mirrors HealthLogSampleTypeRegistry).
                "HKQuantityTypeIdentifierTimeInDaylight": .timeInDaylight,
                HKQuantityTypeIdentifier.restingHeartRate.rawValue: .restingHeartRate,
                HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: .hrv,
                HKQuantityTypeIdentifier.vo2Max.rawValue: .vo2Max,
                HKQuantityTypeIdentifier.walkingSpeed.rawValue: .walkingSpeed,
                HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue: .walkingAsymmetry,
                HKQuantityTypeIdentifier.walkingStepLength.rawValue: .walkingStepLength,
                HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue: .walkingDoubleSupport,
                HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue: .walkingSteadiness,
                HKQuantityTypeIdentifier.respiratoryRate.rawValue: .respiratoryRate,
                HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue: .audioExposureEnvironment,
                HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue: .audioExposureHeadphone,
                HKQuantityTypeIdentifier.bodyMassIndex.rawValue: .bmi
            ]
            return map
        #else
            return [:]
        #endif
    }()

    /// Per-kind counters. All ints monotonically increase across the session;
    /// timestamps are last-event semantics.
    public struct KindStats: Sendable, Equatable {
        public var identifier: String
        /// Total foreign samples HK has handed us this session via the
        /// observer/anchor pipeline.
        public var samplesReadTotal: Int = 0
        /// Subset of `samplesReadTotal` the server accepted (inserted +
        /// duplicate). `samplesReadTotal - samplesUploadedTotal` = either
        /// skipped (unknown to server) or still in-flight / errored.
        public var samplesUploadedTotal: Int = 0
        /// HK-STATS aggregator counters — only populated for the 5 cumulative
        /// kinds that flow over `HealthKitStatisticsSyncCoordinator`.
        public var statsPostedTotal: Int = 0
        /// Later upserts of an already-posted `stats:<type>:<day>` row.
        public var statsRepostedTotal: Int = 0
        /// Last time the observer/anchor query fired for this identifier
        /// with samples >= 0 (zero-sample wakeups still count — they are
        /// proof of life for the observation pipeline).
        public var lastObservationAt: Date?
        /// Last time an anchor advance actually persisted — that is the
        /// concrete proof that an upload round-trip succeeded.
        public var lastAnchorAdvancedAt: Date?
        /// Last time the HK-STATS path posted or upserted for this identifier.
        public var lastStatsActionAt: Date?

        public init(identifier: String) {
            self.identifier = identifier
        }

        /// Merge two entries (used by `snapshotByKind` to combine BP-sys +
        /// BP-dia into a single `.bloodPressure` row). Counters add; dates
        /// pick the most recent.
        func merging(_ other: KindStats) -> KindStats {
            var merged = self
            merged.samplesReadTotal += other.samplesReadTotal
            merged.samplesUploadedTotal += other.samplesUploadedTotal
            merged.statsPostedTotal += other.statsPostedTotal
            merged.statsRepostedTotal += other.statsRepostedTotal
            merged.lastObservationAt = Self.latest(lastObservationAt, other.lastObservationAt)
            merged.lastAnchorAdvancedAt = Self.latest(lastAnchorAdvancedAt, other.lastAnchorAdvancedAt)
            merged.lastStatsActionAt = Self.latest(lastStatsActionAt, other.lastStatsActionAt)
            return merged
        }

        private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
            switch (lhs, rhs) {
            case let (.some(a), .some(b)): max(a, b)
            case let (.some(a), nil): a
            case let (nil, .some(b)): b
            case (nil, nil): nil
            }
        }
    }
}
