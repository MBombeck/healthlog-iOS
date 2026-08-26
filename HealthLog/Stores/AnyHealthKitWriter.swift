import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Budget policy for a direct workout synchronization pass.
public enum WorkoutSyncPassMode: Sendable, Equatable, Hashable {
    /// One anchored query only. Callers must already have a persisted anchor so
    /// a short wake can never turn into an unbounded first-history import.
    case incrementalOnly

    /// One anchored query followed by at most one HR-history page.
    case processing

    var includesHistoryCatchUp: Bool {
        self == .processing
    }
}

/// Type-Erasure damit Stores in Tests ohne HK-Framework nutzbar bleiben.
public protocol AnyHealthKitWriter: Sendable {
    func write(_ measurement: Measurement) async throws

    /// **W-HKMIRROR** — mirror SERVER-ORIGIN measurements (entered on web /
    /// another device, or imported) into Apple Health. Closes the bidirectional
    /// gap where only `.manual` rows round-tripped. Source/kind policy +
    /// anti-dup (externalUUID) + idempotency live in the implementation; the
    /// caller passes the authoritative server page. Skips silently without
    /// share-auth; non-HK builds + test doubles no-op via the default below.
    func mirrorServerMeasurements(_ measurements: [Measurement]) async

    /// S4 / QA6 #2: mirror a MoodEntry into HKStateOfMindSample. iOS 18+
    /// only; pre-18 implementations no-op.
    func writeMood(_ entry: MoodEntry) async throws

    /// **v0.10.0 W10 M1** — delete the HKStateOfMind sample mirrored for a mood
    /// entry (looked up by `HKMetadataKeyExternalUUID == id`) so a deleted mood
    /// doesn't linger in Apple Health. iOS 18+ / HK builds; otherwise no-op.
    func deleteMood(id: String) async throws

    /// **v0.10.0 W-Mood-B** — request State-of-Mind read+share auth.
    /// 16-03/E2: the type is now in the first sheet's default sets, so this is
    /// the recovery path behind the `syncMoodWithAppleHealth` Settings toggle
    /// rather than the first ask. iOS 18+; older OS + non-HK builds no-op.
    func requestMoodAuthorization() async throws

    /// **v0.10.0 W-Mood-B** — start importing foreign `HKStateOfMind` samples
    /// (logged in Apple Health / Journal / elsewhere) into HealthLog mood via
    /// `MoodRepository`, anti-duped against our own writes. Idempotent.
    func startMoodImport(repo: MoodRepository, userID: String?) async

    /// Runs one explicit anchored State-of-Mind sweep while preserving the
    /// existing observer. Used by “sync now” only after the device-local mood
    /// opt-in is already enabled; it never requests authorization itself.
    func refreshMoodImport(repo: MoodRepository, userID: String?) async

    /// **v0.10.0 W-Mood-B** — stop the State-of-Mind import observer (toggle
    /// off / logout).
    func stopMoodImport() async

    /// **v0.10.0 W10 M2** — reset the per-user State-of-Mind import anchor and
    /// stop the observer (logout / user-change). The next user must start clean:
    /// without this, a different user signing in on the same device re-imports
    /// the full HKStateOfMind history into their account. iOS 18+ / HK builds;
    /// non-HK no-op.
    func resetMoodImport() async

    /// Aktiviert HK-Background-Deliveries für alle vom Service unterstützten Default-Read-Types.
    /// Idempotent: System-Side-Effect, aber wiederholtes `enableBackgroundDelivery` ist unproblematisch
    /// und wird vom System zusammengefasst. **Darf erst nach erteilter HK-Berechtigung aufgerufen
    /// werden** (sonst wirft HealthKit `notAuthorized`).
    func activateBackgroundDeliveries() async throws

    /// Führt einen einmaligen Sync-Pass aus, der alle bisher von `HKObserverQuery` registrierten
    /// neuen Foreign-Samples gegen den Server abgleicht. Wird vom `BGProcessingTask`-Handler
    /// und vom Foreground-Bootstrap aufgerufen.
    func runBackgroundSyncPass() async

    /// Wird vom Composition-Root nach AppContainer-Init aufgerufen, sobald die
    /// APIClient-abhängige `MeasurementBatchUploader`-Instance existiert. Vor dem
    /// Set ist der Service ein no-op-Sink (Foreign-Samples werden geloggt aber
    /// nicht hochgeladen) — dadurch crasht ein Observer-Wakeup vor dem Boot
    /// nicht.
    func attachUploader(_ uploader: MeasurementBatchUploader) async

    /// Reconciler for HK-deletions (S2): forwards `deletedObjects` from
    /// HKAnchoredObjectQuery to the server `DELETE
    /// /api/measurements/by-external-ids` route.
    func attachDeletionReconciler(_ reconciler: MeasurementDeletionReconciler) async

    /// Setzt den Lower-Bound-Cutoff fuer den ersten HK-Sync per Type. Wird aus
    /// dem OnboardingFlow-Backfill-Window-Picker getrieben (A1-Audit H7). Pro
    /// Type wirkt der Cutoff nur solange noch kein Anchor persistiert ist —
    /// danach uebernimmt der Anchor.
    /// nil = "Alle / kein Cutoff" (Default-Verhalten ohne Backfill-Window).
    func setInitialBackfillCutoff(_ cutoff: Date?) async

    /// v0.5.5 W-A3 setter-injection for the feature-flags reader. The
    /// HK-STATS daily-stats gate (`enableDailyStats`) reads from this seam.
    /// (The former Spezi-cutover skip-filter flags were removed in the v0162
    /// cleanup once the legacy per-sample observer pipeline was retired.)
    /// Idempotent — safe to call multiple times.
    func attachFeatureFlags(_ featureFlags: (any FeatureFlagsServicing)?) async

    /// **Phase 07 / plan 07-05** — setter-injection for the account admission the
    /// opt-in importers sweep under.
    ///
    /// Same shape and the same reason as ``attachFeatureFlags(_:)``: this
    /// protocol is `public` while the Phase-07 lease vocabulary is
    /// module-internal, so the admission crosses the seam inside
    /// ``HealthSyncImporterAdmission`` — a public carrier with an internal
    /// payload. Idempotent. Implementations that own no importer no-op via the
    /// default below.
    func attachHealthSyncAdmission(_ admission: HealthSyncImporterAdmission?) async

    /// **Phase 07 / plan 07-06** — setter-injection for the owner-bound outbox a
    /// held heart-event page is written to. Same shape and the same reason as
    /// ``attachHealthSyncAdmission(_:)``. Idempotent; implementations that own no
    /// importer no-op via the default below.
    func attachHealthSyncRetryQueue(_ queue: OutboxQueue?) async

    // MARK: - Workouts (v1.15 W-WORKOUT)

    /// **v1.15 W-WORKOUT** — start collecting `HKWorkout` and uploading it to
    /// `POST /api/workouts/batch` so the existing Workouts UI populates. Always-
    /// on (a core surface, not toggle-gated); the caller invokes it once
    /// HealthKit is authorised. `onIngest` fires after a sweep ingests ≥1
    /// workout so the `WorkoutsStore` revalidates. Idempotent. Non-HK builds
    /// no-op.
    ///
    /// **W-B184** — `forceFullSweep: true` clears the persisted anchor BEFORE
    /// starting, so the first sweep re-backfills the full HKWorkout history. The
    /// workout-read re-auth migration (`HKReadinessStore`) passes `true` for
    /// returning users: a pre-b182 build may have advanced the anchor over an
    /// empty (read-unauthorized) sweep, permanently masking history; resetting
    /// here recovers it once auth lands. Default `false` (normal launch).
    func startWorkoutImportIfNeeded(
        repo: WorkoutsRepository,
        userID: String?,
        forceFullSweep: Bool,
        onIngest: (@Sendable () async -> Void)?
    ) async

    /// Runs one bounded direct workout pass without relying on a mounted view.
    /// Returns `false` when no authenticated user is available or an
    /// incremental-only wake has no persisted anchor yet.
    @discardableResult
    func runWorkoutSyncPass(
        repo: WorkoutsRepository,
        userID: String?,
        mode: WorkoutSyncPassMode,
        onIngest: (@Sendable () async -> Void)?
    ) async -> Bool

    /// **v1.15 W-WORKOUT** — stop the workout import observer (logout).
    func stopWorkoutImportObserver() async

    /// **v1.15 W-WORKOUT** — reset the per-user workout import anchor and stop
    /// the observer (logout / user-change), so the next user starts clean.
    func resetWorkoutImportObserver() async

    // MARK: - Heart-health + mobility EVENTS (W-HKREAD)

    /// **W-HKREAD** — start importing categorical EVENT-class HealthKit samples
    /// (irregular-rhythm, high/low-HR, walking-steadiness, sleep-apnea,
    /// audio-exposure events) and forwarding the device's verdict to
    /// `POST /api/measurements/batch`. Always-on (a core read surface, not
    /// toggle-gated). Requires the uploader to be attached first. Idempotent.
    /// Non-HK builds no-op.
    func startEventImportIfNeeded(userID: String?) async

    /// **Phase 07 / plan 07-07** — ensure the event importer exists, then force
    /// exactly one bounded anchored read of every event type, and report what it
    /// did. The route the orchestrator's `heartHealthEvents` capability takes.
    ///
    /// Plan 07-06 gave `HeartHealthEventImporter.refresh()` a named disposition
    /// and deliberately did not add this wrapper, because a wrapper nothing can
    /// call is a false statement about the app. This plan adds it in the commit
    /// that gives it a caller.
    func refreshEventImport(userID: String?) async -> HealthSyncImportOutcome

    /// **W-HKREAD** — stop the event import observers (logout).
    func stopEventImportObserver() async

    /// **W-HKREAD** — reset every per-type event anchor and stop the observers
    /// (logout / user-change), so the next user starts clean.
    func resetEventImportObserver() async

    // MARK: - Cycle (reproductive-health) — Phase C2/C4

    /// **v0.14.8 C4** — request the full reproductive-category read+share auth
    /// set. Only reached once `CycleGate.isCycleTrackingAvailable` is true (men
    /// are never prompted). iOS 18+ / HK builds; otherwise no-op.
    func requestCycleAuthorizationIfNeeded() async throws

    // MARK: - Nutrients (GH #48)

    /// **GH #48** — request read authorization for the nutrient catalog types.
    /// Only reached once the opt-in `nutrients` module is ENABLED (the dietary
    /// types are kept out of the always-on onboarding sheet, so a user who never
    /// switches nutrients on is never prompted). Read-only. HK builds; otherwise
    /// no-op.
    func requestNutrientAuthorizationIfNeeded() async throws

    // MARK: - ECG (GH #74)

    /// **GH #74** — request READ authorization for `HKElectrocardiogramType`.
    /// 16-03/E2: the type is now in the always-on first sheet, so this is the
    /// recovery path for a user who declined there and later turns the
    /// device-local switch on (``EcgHealthSyncStore``), not the first ask.
    /// Read-only — the app never writes an ECG back. HK builds; otherwise no-op.
    func requestEcgAuthorizationIfNeeded() async throws

    /// **v0.14.8 C4** — mirror a MANUAL cycle day-log into Apple Health (gated
    /// on a 2xx server write). `isCycleStart` flags the period-start day — it
    /// feeds the REQUIRED `HKMetadataKeyMenstrualCycleStart` metadata on the
    /// menstrual-flow sample. iOS 18+ / HK builds; otherwise no-op.
    func writeCycleDayLogToHealth(_ dayLog: CycleDayLogDTO, isCycleStart: Bool) async throws

    /// **v0.14.8 C2/C4** — start importing foreign reproductive samples into
    /// HealthLog cycle via `CycleRepository`, anti-duped against our own writes.
    /// Idempotent. Caller gates on `CycleGate`.
    func startCycleImportIfEligible(repo: CycleRepository, userID: String?) async

    /// **Phase 07 / plan 07-07** — ensure the cycle importer exists, then force
    /// exactly one bounded anchored read of every reproductive type, and report
    /// what it did. The route the orchestrator's `cycleImport` capability takes.
    func refreshCycleImport(repo: CycleRepository, userID: String?) async -> HealthSyncImportOutcome

    /// **v0.14.8 C2/C4** — stop the cycle import observer (gate closed / logout).
    func stopCycleImportObserver() async

    /// **v0.14.8 C2/C4** — reset the per-user cycle import anchors and stop the
    /// observer (logout / user-change), so the next user starts clean.
    func resetCycleImportObserver() async

    /// **No-prompt** read of the cached HealthKit biological-sex characteristic,
    /// mapped to a platform-free signal for the cycle gate's resolution path #3.
    /// NEVER triggers an authorization prompt; returns `.unknown` whenever auth
    /// was not granted independently (so the fallback contributes nothing and men
    /// are NEVER surfaced the feature). iOS 18+ / HK builds; otherwise `.unknown`.
    func cycleBiologicalSex() async -> CycleGateResolver.BiologicalSexSignal
}

public extension AnyHealthKitWriter {
    /// Default no-op so non-HK test doubles need not implement the server mirror.
    func mirrorServerMeasurements(_: [Measurement]) async {}

    /// Default no-op: an implementation that owns no opt-in importer has no
    /// account to admit. The live HealthKit service overrides it.
    func attachHealthSyncAdmission(_: HealthSyncImporterAdmission?) async {}

    /// Default no-op: an implementation that owns no importer has no page to
    /// make durable. The live HealthKit service overrides it.
    func attachHealthSyncRetryQueue(_: OutboxQueue?) async {}

    /// Non-HK/test default: starting the importer is the closest available
    /// behavior. The live HealthKit service overrides this with an explicit
    /// one-shot sweep when the observer already exists.
    func refreshMoodImport(repo: MoodRepository, userID: String?) async {
        await startMoodImport(repo: repo, userID: userID)
    }

    /// Default no-ops so non-HK test doubles need not implement the workout seam.
    func startWorkoutImportIfNeeded(
        repo _: WorkoutsRepository,
        userID _: String?,
        forceFullSweep _: Bool,
        onIngest _: (@Sendable () async -> Void)?
    ) async {}
    func runWorkoutSyncPass(
        repo _: WorkoutsRepository,
        userID _: String?,
        mode _: WorkoutSyncPassMode,
        onIngest _: (@Sendable () async -> Void)?
    ) async -> Bool {
        false
    }

    func stopWorkoutImportObserver() async {}
    func resetWorkoutImportObserver() async {}

    // Default no-ops so non-HK test doubles need not implement the event seam.
    func startEventImportIfNeeded(userID _: String?) async {}
    func stopEventImportObserver() async {}
    func resetEventImportObserver() async {}

    /// A double or a non-HK build states `unsupported` rather than a silent
    /// success — the orchestrator's plan still names the capability.
    func refreshEventImport(userID _: String?) async -> HealthSyncImportOutcome {
        .unsupported
    }

    /// Default no-op so non-HK test doubles need not implement the nutrient seam.
    func requestNutrientAuthorizationIfNeeded() async throws {}

    /// Default no-op so non-HK test doubles need not implement the ECG seam.
    func requestEcgAuthorizationIfNeeded() async throws {}

    // Default no-ops so non-HK test doubles need not implement the cycle seam.
    func requestCycleAuthorizationIfNeeded() async throws {}
    func writeCycleDayLogToHealth(_: CycleDayLogDTO, isCycleStart _: Bool) async throws {}
    func startCycleImportIfEligible(repo _: CycleRepository, userID _: String?) async {}
    func refreshCycleImport(repo _: CycleRepository, userID _: String?) async -> HealthSyncImportOutcome {
        .unsupported
    }

    func stopCycleImportObserver() async {}
    func resetCycleImportObserver() async {}
    func cycleBiologicalSex() async -> CycleGateResolver.BiologicalSexSignal {
        .unknown
    }
}

#if canImport(HealthKit)
    extension HealthKitService: AnyHealthKitWriter {
        public func write(_ measurement: Measurement) async throws {
            try await writeMeasurement(measurement)
        }

        public func writeMood(_ entry: MoodEntry) async throws {
            try await writeMoodEntry(entry)
        }

        public func deleteMood(id: String) async throws {
            try await deleteMoodEntry(id: id)
        }

        public func startMoodImport(repo: MoodRepository, userID: String?) async {
            await startStateOfMindImport(repo: repo, userID: userID)
        }

        public func refreshMoodImport(repo: MoodRepository, userID: String?) async {
            await refreshStateOfMindImport(repo: repo, userID: userID)
        }

        public func stopMoodImport() async {
            await stopStateOfMindImport()
        }

        public func resetMoodImport() async {
            await resetStateOfMindImport()
        }

        public func activateBackgroundDeliveries() async throws {
            try await startBackgroundDeliveries()
        }

        public func runBackgroundSyncPass() async {
            await runOneShotAnchorSweep()
        }

        public func attachUploader(_ uploader: MeasurementBatchUploader) async {
            setUploader(uploader)
        }

        public func attachDeletionReconciler(_ reconciler: MeasurementDeletionReconciler) async {
            setDeletionReconciler(reconciler)
        }

        // setInitialBackfillCutoff(_:) ist auf dem Actor selbst deklariert —
        // der erfuellt das `async`-Protokoll-Requirement automatisch via
        // Actor-Isolation-Hop.

        // MARK: - Workouts (v1.15 W-WORKOUT)

        public func startWorkoutImportIfNeeded(
            repo: WorkoutsRepository,
            userID: String?,
            forceFullSweep: Bool,
            onIngest: (@Sendable () async -> Void)?
        ) async {
            await startWorkoutImport(
                repo: repo,
                userID: userID,
                forceFullSweep: forceFullSweep,
                onIngest: onIngest
            )
        }

        public func stopWorkoutImportObserver() async {
            await stopWorkoutImport()
        }

        public func resetWorkoutImportObserver() async {
            await resetWorkoutImport()
        }

        // MARK: - Heart-health + mobility EVENTS (W-HKREAD)

        public func startEventImportIfNeeded(userID: String?) async {
            await startEventImport(userID: userID)
        }

        public func refreshEventImport(userID: String?) async -> HealthSyncImportOutcome {
            await refreshHeartEventImport(userID: userID)
        }

        public func stopEventImportObserver() async {
            await stopEventImport()
        }

        public func resetEventImportObserver() async {
            await resetEventImport()
        }

        // MARK: - Cycle (C2/C4)

        public func requestCycleAuthorizationIfNeeded() async throws {
            try await requestCycleAuthorization()
        }

        public func refreshCycleImport(repo: CycleRepository, userID: String?) async -> HealthSyncImportOutcome {
            await refreshCycleImportSweep(repo: repo, userID: userID)
        }

        // MARK: - Nutrients (GH #48)

        public func requestNutrientAuthorizationIfNeeded() async throws {
            try await requestNutrientAuthorization()
        }

        // MARK: - ECG (GH #74)

        public func requestEcgAuthorizationIfNeeded() async throws {
            try await requestEcgAuthorization()
        }

        public func writeCycleDayLogToHealth(_ dayLog: CycleDayLogDTO, isCycleStart: Bool) async throws {
            try await writeCycleDayLog(dayLog, isCycleStart: isCycleStart)
        }

        public func startCycleImportIfEligible(repo: CycleRepository, userID: String?) async {
            await startCycleImport(repo: repo, userID: userID)
        }

        public func stopCycleImportObserver() async {
            await stopCycleImport()
        }

        public func resetCycleImportObserver() async {
            await resetCycleImport()
        }

        public func cycleBiologicalSex() async -> CycleGateResolver.BiologicalSexSignal {
            cycleBiologicalSexSignal()
        }
    }
#endif
