import Foundation

// Direct-workout + backfill lifecycle state remains beside the importer owner
// so cancellation and replacement are one actor transaction. The actor is
// intentionally cohesive despite crossing the generic size thresholds.
// swiftlint:disable file_length type_body_length
#if canImport(HealthKit)

    import HealthKit
#endif

#if canImport(HealthKit)

    // `HealthKitServiceProtocol` lives in `HealthLog/Services/HealthKit/
    // HealthKitServiceProtocol.swift` since v0.5.5 Phase A.2 — the seam
    // grew enough public surface (auth + status batching + default-type-set
    // accessors) that keeping it inline here muddled the actor's primary
    // role. The file split also lets the Spezi-backed implementation
    // plug in without churn on `HealthKitService.swift`.

    /// Facade exposing HK auth + write-back + utility statics for the
    /// HealthLog app target. The per-sample observer pipeline
    /// (`HKAnchoredObjectQuery`) was moved to SpeziHealthKit in v0.5.5
    /// (W-A5 trim); Spezi's `HealthLogStandard` is now the authoritative
    /// receiver of all HK-stream events for the 16 sample types the app
    /// reads, and SpeziLocalStorage owns the live anchor store post the
    /// W-A3 anchor migrator handover. The facade still owns: HK auth +
    /// status batching (consumed by `HKReadinessStore` +
    /// `HealthKitPermissionStep`); the default Read/Write type-sets; the
    /// BF-5 write-back path (`HealthKit/HealthKitService+Write.swift`)
    /// and `writeMoodEntry(_:)`; the utility statics (`partitionToken`,
    /// `clearAnchors`, `uploadAndDecide`); logout-time legacy anchor-key
    /// wipe via `clearAnchors(for:in:)` (keys read-only-historic now,
    /// retained per PB12 rollback safety); and no-op shims for
    /// `startBackgroundDeliveries()` + `runOneShotAnchorSweep()` so
    /// `MeasurementsStore`'s `AnyHealthKitWriter` extension keeps
    /// compiling unchanged — that extension is the only remaining caller
    /// of the shimmed sweep (`runBackgroundSyncPass` →
    /// `runOneShotAnchorSweep`), through which
    /// `BackgroundSyncCoordinator.handleBGTask` + `HKReadinessStore
    /// .triggerManualSync` transit.
    ///
    /// **v0.5.6 sweep:** the dead-runtime Spezi-cutover filter helpers
    /// (`speziCutoverDroppedIdentifiers` / `applySpeziCutoverFilter`),
    /// the static `preferredFrequency(for:)` mapping, and the
    /// `isAuthNotDeterminedError(_:)` classifier were removed — none of
    /// them had a runtime call-site post-W-A5; the only references were
    /// in test fixtures pinning a contract that no production path
    /// reads. Reinstate from git history if a future rollback flips the
    /// legacy observer pipeline back on.
    public actor HealthKitService: HealthKitServiceProtocol {
        public let store: HKHealthStore
        private let keychain: KeychainStoring
        private let bundleID: String
        /// Optional FeatureFlags-Service stash. Post-W-A5 + v0.5.6
        /// dead-shim-sweep no runtime path on this actor reads from it;
        /// the property remains as the storage backing
        /// `attachFeatureFlags(_:)` so the protocol seam stays
        /// satisfiable. The call-site in `AppContainer.init` keeps
        /// invoking the setter idempotently — that wiring is preserved
        /// because flipping the legacy observer pipeline back on would
        /// reinstate a per-sample reader against this property.
        private var featureFlags: (any FeatureFlagsServicing)?

        /// Setter-injection for the feature-flags reader. Idempotent;
        /// safe to call multiple times (each call overwrites). Post-W-A5
        /// the live reader is no longer consumed by a per-sample path —
        /// the call-site stays in `AppContainer.init` to preserve the
        /// rollback contract.
        public func attachFeatureFlags(_ featureFlags: (any FeatureFlagsServicing)?) {
            self.featureFlags = featureFlags
        }

        /// **Phase 07 / plan 07-05** — the account the opt-in State-of-Mind
        /// importer sweeps under, and the owner-partitioned cursor store its
        /// anchor is committed through.
        ///
        /// Setter-injection for the same reason `attachFeatureFlags(_:)` is: the
        /// composition root owns the Phase-06 lease registry and this actor is
        /// constructed before it. Rebuilding the importer on binding is
        /// deliberate — one built before the binding admits nothing and would
        /// refuse every sweep.
        private var healthSyncAdmission: HealthSyncImporterAdmission?
        private let healthSyncCursors = DurableHealthCursorStore()
        /// The owner-bound outbox a held heart-event page is written to.
        private var healthSyncRetryQueue: OutboxQueue?

        public func attachHealthSyncAdmission(_ admission: HealthSyncImporterAdmission?) async {
            healthSyncAdmission = admission
            // Launch-order gap: the composition root binds this from a detached
            // task, and `MoodHealthSyncStore.activateIfEnabled()` may already
            // have started an importer that admits nothing — one that refuses
            // every sweep until something else happens to restart it. Rebuild it
            // here, under the same inputs, so the binding closes the window it
            // opens instead of leaving the first sweep of a session lost.
            let restart = moodImporterInputs
            await moodImporter?.stop()
            moodImporter = nil
            // Plan 07-06 — the cycle and heart-event importers have the same
            // window, and the heart-event one is worse: it is always-on, so a
            // cold launch reaches it before the composition root binds anything.
            let restartCycle = cycleImporterInputs
            await cycleImporter?.stop()
            cycleImporter = nil
            let restartEvents = eventImporterInputs
            await eventImporter?.stop()
            eventImporter = nil
            guard admission != nil else { return }
            if let restart {
                await startStateOfMindImport(repo: restart.repo, userID: restart.userID)
            }
            if let restartCycle {
                await startCycleImport(repo: restartCycle.repo, userID: restartCycle.userID)
            }
            if let restartEvents {
                await startEventImport(userID: restartEvents.userID)
            }
        }

        /// **Phase 07 / plan 07-06** — the durable landing place for a heart-event
        /// page the server did not terminally accept.
        ///
        /// Setter-injection for the same reason the admission is: the composition
        /// root owns the outbox and this actor is constructed before it. A live
        /// importer is rebuilt on binding, exactly as for the admission, so the
        /// binding closes the window it opens.
        public func attachHealthSyncRetryQueue(_ queue: OutboxQueue?) async {
            healthSyncRetryQueue = queue
            let restartEvents = eventImporterInputs
            await eventImporter?.stop()
            eventImporter = nil
            guard let restartEvents, queue != nil else { return }
            await startEventImport(userID: restartEvents.userID)
        }

        /// What the live heart-event importer was built from.
        struct EventImportInputs: Sendable {
            let userID: String?
        }

        /// Composition-root-injected uploader. Retained post-W-A5 as a
        /// no-op surface — the legacy observer pipeline that consumed it
        /// is gone (`HealthLogStandard` owns the per-sample upload path
        /// now). The setter stays because `AppContainer.init` wires it
        /// idempotently; treating that as load-bearing keeps the
        /// composition root minimal-touch.
        private var uploader: MeasurementBatchUploader?

        public func setUploader(_ uploader: MeasurementBatchUploader?) {
            self.uploader = uploader
        }

        /// Composition-root-injected reconciler. Retained post-W-A5 as a
        /// no-op surface — the legacy `HKAnchoredObjectQuery` `deletedObjects`
        /// callback that consumed it is gone. Spezi's `HealthLogStandard`
        /// owns the per-collector delete signal now (currently a no-op
        /// itself; the server-side reconcile path runs through other
        /// channels).
        private var deletionReconciler: MeasurementDeletionReconciler?

        public func setDeletionReconciler(_ reconciler: MeasurementDeletionReconciler?) {
            deletionReconciler = reconciler
        }

        /// Lower-Bound-Cutoff fuer den ersten Sync per Type.
        ///
        /// **v0.7.0 W-STEPS Layer 2 — superseded by the window-store
        /// read in `HealthLogSpeziDelegate.resolvedBackfillCutoff()`.**
        /// The Spezi-side `CollectSamples` declarations now read the
        /// operator-chosen `HealthKitBackfillWindow` directly from the
        /// per-User UserDefaults shape (`HealthKitBackfillWindowStore`)
        /// that `AppContainer.setHealthKitBackfillWindow` writes during
        /// onboarding, and pass `timeRange: .startingAt(cutoff)` into
        /// each collector. That makes this setter a no-op for the live
        /// HK sync path — the `Date` we cache here is never consumed.
        ///
        /// We keep the setter callable (and store the cached date) so
        /// the existing `AppContainer.setHealthKitBackfillWindow` +
        /// `AppContainer.restoreHealthKitBackfillWindow` call-sites
        /// continue to compile unchanged; rollback to a hypothetical
        /// non-Spezi observer pipeline (PB12 rollback contract) would
        /// re-light a consumer for this property.
        public func setInitialBackfillCutoff(_ cutoff: Date?) {
            initialBackfillCutoff = cutoff
        }

        private var initialBackfillCutoff: Date?

        public nonisolated func isAvailable() -> Bool {
            HKHealthStore.isHealthDataAvailable()
        }

        public nonisolated func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
            store.authorizationStatus(for: type)
        }

        public func requestAuthorization(read: Set<HKObjectType>, write: Set<HKSampleType>) async throws {
            try await store.requestAuthorization(toShare: write, read: read)
        }

        // MARK: - Default Type-Sets, instance accessors

        //
        // The static `defaultReadTypes` / `eventReadTypes` / `defaultWriteTypes`
        // sets and the `defaultReadTypes()` / `defaultWriteTypes()` protocol-seam
        // accessors live in `HealthKit/HealthKitService+TypeSets.swift`
        // (file_length discipline extract).

        // MARK: - Write (Anti-Duplikat)

        //
        // The actual `writeMeasurement(_:)` branch table lives in
        // `HealthKit/HealthKitService+Write.swift` (v0.5.4 BF-5 extract). The
        // protocol still declares the method on this actor; the extension
        // satisfies it.

        /// Bidirectional mood-sync (S4 / QA6 #2). Mirrors a MoodEntry into
        /// HKStateOfMindSample so the user's stimmung shows up in the
        /// system Health app alongside other mood-aware integrations
        /// (Journal, Mindfulness). iOS 18+ — silent no-op on older OS,
        /// kept guarded so we can keep iOS 17 in deployment-target window
        /// if Spezi-migration pushes us back.
        public func writeMoodEntry(_ entry: MoodEntry) async throws {
            guard #available(iOS 18.0, *) else { return }
            let metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: entry.id,
                HKMetadataKeyWasUserEntered: true
            ]
            // Score 1..5 → HKStateOfMind.Valence -1.0 ... 1.0 via the shared
            // mapping (let `valenceClassification` derive — never set manually).
            let valence = MoodStateOfMindMapping.valence(forScore: entry.score)
            // v0.10.0 W-Mood-B — `.dailyMood` (was `.momentaryEmotion`):
            // HealthLog mood is a check-in about how the user feels overall,
            // which is the semantic match + renders in Health's "Mood" track.
            let sample = HKStateOfMind(
                date: entry.recordedAt,
                kind: .dailyMood,
                valence: valence,
                labels: MoodStateOfMindMapping.labels(forTags: entry.tags),
                associations: MoodStateOfMindMapping.associations(forTags: entry.tags),
                metadata: metadata
            )
            try await store.save(sample)
        }

        /// **v0.10.0 W-Mood-B** — request read+share auth for State of Mind
        /// only.
        ///
        /// **16-03 / decision E2 — the type is now in
        /// `defaultReadTypes`/`defaultWriteTypes`, which drive the always-on
        /// first sheet.** This entry point stays, and is not dead code: it is
        /// the path a user takes who declined the first sheet and later turns
        /// the Settings toggle on. Without the permission the existing write
        /// silently no-ops (`HKErrorAuthorizationDenied` swallowed by `try?` in
        /// `MoodStore`), which is why it is asked for at all. iOS 18+ — no-op on
        /// older OS, though the deployment target is 18.0 so that guard is
        /// belt-and-braces.
        public func requestMoodAuthorization() async throws {
            guard #available(iOS 18.0, *) else { return }
            let type = HKObjectType.stateOfMindType()
            try await store.requestAuthorization(toShare: [type], read: [type])
        }

        /// v0.10.0 W-Mood-B — owns the State-of-Mind import observer so its
        /// lifecycle (start/stop) is actor-isolated alongside `store`.
        private var moodImporter: MoodStateOfMindImporter?

        /// What the live importer was built from, so an admission bound after it
        /// started can rebuild the same importer rather than silently disabling
        /// mood import for the rest of the session.
        private var moodImporterInputs: (repo: MoodRepository, userID: String?)?

        /// Start (or no-op if already running) the foreign-State-of-Mind →
        /// HealthLog mood importer.
        func startStateOfMindImport(repo: MoodRepository, userID: String?) async {
            guard #available(iOS 18.0, *) else { return }
            moodImporterInputs = (repo, userID)
            if moodImporter == nil {
                moodImporter = MoodStateOfMindImporter(
                    store: store,
                    repo: repo,
                    userID: userID,
                    admission: healthSyncAdmission?.provider(for: .mood),
                    cursors: healthSyncCursors
                )
            }
            await moodImporter?.start()
        }

        /// Ensure the observer exists, then force exactly one current anchored
        /// read. If this call creates the importer, `start()` already performs
        /// that read; an existing importer receives the explicit refresh.
        func refreshStateOfMindImport(repo: MoodRepository, userID: String?) async {
            guard #available(iOS 18.0, *) else { return }
            if moodImporter == nil {
                await startStateOfMindImport(repo: repo, userID: userID)
            } else {
                await moodImporter?.refresh()
            }
        }

        /// Stop + release the importer (toggle off / logout).
        func stopStateOfMindImport() async {
            await moodImporter?.stop()
            moodImporter = nil
            // An explicit stop is a decision, not a launch-order accident: drop
            // the restart inputs so a later admission binding cannot revive an
            // importer the toggle or the logout just turned off.
            moodImporterInputs = nil
        }

        /// **v0.10.0 W10 M2 — reset the per-user import anchor, then stop.**
        ///
        /// Called on logout / user-change so the next user starts from a clean
        /// anchor (the importer holds the just-logged-out user's per-user anchor
        /// key, so this clears exactly that partition). No-op when no importer is
        /// live (toggle was off) — in that case the caller still forces the
        /// device-local toggle off, which prevents auto-activation for the next
        /// user.
        func resetStateOfMindImport() async {
            await moodImporter?.resetAnchor()
            await moodImporter?.stop()
            moodImporter = nil
            moodImporterInputs = nil
        }

        // MARK: - Cycle (reproductive-health) — Phase C2

        /// Owns the cycle import observer (lifecycle is actor-isolated alongside
        /// `store`). The stateless cycle methods live in `HealthKitService+Cycle`.
        var cycleImporter: CycleHealthKitImporter?

        /// What the live cycle importer was built from, so an admission bound
        /// after it started can rebuild the same importer rather than leaving
        /// cycle import refusing for the rest of the session.
        private var cycleImporterInputs: (repo: CycleRepository, userID: String?)?

        /// Start (or no-op if already running) the foreign-reproductive-sample →
        /// HealthLog cycle importer. Caller gates on `CycleGate`.
        func startCycleImport(repo: CycleRepository, userID: String?) async {
            guard #available(iOS 18.0, *) else { return }
            cycleImporterInputs = (repo, userID)
            if cycleImporter == nil {
                cycleImporter = CycleHealthKitImporter(
                    store: store,
                    repo: repo,
                    userID: userID,
                    admission: healthSyncAdmission?.provider(for: .cycle),
                    cursors: healthSyncCursors
                )
            }
            await cycleImporter?.start()
        }

        /// **Phase 07 / plan 07-07** — ensure the importer exists, then force one
        /// bounded anchored read of every reproductive type and report the
        /// worst-of disposition across them.
        ///
        /// If this call creates the importer, `start()` already performs that
        /// read and its own disposition is the answer; an existing importer
        /// receives the explicit refresh. Below iOS 18 there is no importer to
        /// build, and the answer is `unsupported` rather than a silent success.
        func refreshCycleImportSweep(repo: CycleRepository, userID: String?) async -> HealthSyncImportOutcome {
            guard #available(iOS 18.0, *) else { return .unsupported }
            if cycleImporter == nil {
                cycleImporterInputs = (repo, userID)
                cycleImporter = CycleHealthKitImporter(
                    store: store,
                    repo: repo,
                    userID: userID,
                    admission: healthSyncAdmission?.provider(for: .cycle),
                    cursors: healthSyncCursors
                )
                guard let disposition = await cycleImporter?.start() else { return .unsupported }
                return HealthSyncImportOutcome(disposition: disposition)
            }
            guard let disposition = await cycleImporter?.refresh() else { return .unsupported }
            return HealthSyncImportOutcome(disposition: disposition)
        }

        /// Stop + release the cycle importer (gate closed / logout).
        func stopCycleImport() async {
            await cycleImporter?.stop()
            cycleImporter = nil
            // An explicit stop is a decision, not a launch-order accident: drop
            // the restart inputs so a later admission binding cannot revive an
            // importer the gate or the logout just turned off.
            cycleImporterInputs = nil
        }

        /// Reset the per-user cycle import anchors, then stop. Called on logout /
        /// user-change so the next user starts from a clean anchor.
        func resetCycleImport() async {
            await cycleImporter?.resetAnchors()
            await cycleImporter?.stop()
            cycleImporter = nil
            cycleImporterInputs = nil
        }

        // MARK: - Workouts (v1.15 W-WORKOUT)

        /// Owns the workout import observer (lifecycle actor-isolated alongside
        /// `store`). The mapping is in the pure `WorkoutHealthKitMapping`.
        private var workoutImporter: WorkoutHealthKitImporter?
        private var workoutImporterPartition: String?
        private var workoutImporterLease: WorkoutImportLease?
        private let workoutDirectLeaseRegistry = WorkoutImportLeaseRegistry()

        /// Shared results are keyed by authenticated owner. The coordinator also
        /// serializes account replacement because HealthKit delivery registration
        /// is global even though anchors and repositories are partitioned.
        private let workoutSyncPassCoordinator = WorkoutSyncPassCoordinator()

        /// Start (or no-op if already running) the HKWorkout → server importer.
        /// Always-on (workouts are a core surface, not toggle-gated) — the
        /// caller invokes this once HealthKit is authorised. `onIngest` is the
        /// post-ingest revalidation hook so the `WorkoutsStore` repaints.
        func startWorkoutImport(
            repo: WorkoutsRepository,
            userID: String?,
            forceFullSweep: Bool = false,
            onIngest: (@Sendable () async -> Void)?
        ) async {
            guard let importer = await ensureWorkoutImporter(
                repo: repo,
                userID: userID,
                onIngest: onIngest
            ) else { return }
            // W-B184 — the workout-read re-auth migration forces a full re-sweep
            // for returning users. Clear the persisted anchor first so the next
            // sweep backfills the whole history (a pre-b182 build may have
            // advanced the anchor over an empty, read-unauthorized sweep, which
            // would otherwise keep history masked even after the grant lands).
            // resetAnchor only removes the UserDefaults key; the start() below
            // then runs an anchorless backfill sweep.
            if forceFullSweep {
                guard let lease = workoutImporterLease,
                      await rearmWorkoutHRBackfill(
                          for: Self.canonicalWorkoutOwner(userID),
                          trigger: .authorizationRefresh,
                          lease: lease
                      ) else { return }
                await importer.resetAnchorAndWaitUntilSettled()
                workoutDefaultsBox.clearWorkoutReadRearmPending(for: userID)
            }
            await importer.start()

            // GH #86 — lifecycle-owned rather than detached: logout/account
            // replacement can cancel and await every suspended query/upload
            // before clearing the captured user's state.
            startWorkoutHRBackfillIfNeeded(repo: repo, userID: userID, maxChunks: 4)
        }

        /// Runs a bounded workout pass from composition-root state. The
        /// importer is rebuilt when the authenticated user partition changes,
        /// so an in-process account switch can never reuse another user's
        /// repository/anchor ownership.
        @discardableResult
        public func runWorkoutSyncPass(
            repo: WorkoutsRepository,
            userID: String?,
            mode: WorkoutSyncPassMode,
            onIngest: (@Sendable () async -> Void)?
        ) async -> Bool {
            guard let partition = authenticatedWorkoutPartition(userID: userID) else {
                return false
            }
            if mode == .incrementalOnly,
               !workoutDefaultsBox.hasObject(
                   forKey: "hl.workout.hk.anchor." + Self.partitionToken(for: userID)
               )
            {
                return false
            }

            return await workoutSyncPassCoordinator.run(
                partition: partition,
                mode: mode,
                isCurrent: { [keychain] in
                    Self.canonicalWorkoutOwner(
                        keychain.getString(forKey: KeychainKey.userID)
                    ) == Self.canonicalWorkoutOwner(userID)
                        && keychain.getString(forKey: KeychainKey.authToken) != nil
                },
                operation: { [weak self] requestedMode in
                    guard let self else { return false }
                    return await runOwnedWorkoutPage(
                        repo: repo,
                        userID: userID,
                        mode: requestedMode,
                        onIngest: onIngest
                    )
                }
            )
        }

        private func runOwnedWorkoutPage(
            repo: WorkoutsRepository,
            userID: String?,
            mode: WorkoutSyncPassMode,
            onIngest: (@Sendable () async -> Void)?
        ) async -> Bool {
            guard !Task.isCancelled,
                  let importer = await ensureWorkoutImporter(
                      repo: repo,
                      userID: userID,
                      onIngest: onIngest
                  ) else { return false }
            let outcome = await importer.runBoundedPage(mode: mode)
            guard outcome.didRun, !Task.isCancelled else { return false }
            if mode.includesHistoryCatchUp {
                _ = await runWorkoutHRBackfill(
                    repo: repo,
                    userID: userID,
                    maxChunks: 1
                )
                guard !Task.isCancelled else { return false }
            }
            return true
        }

        private func authenticatedWorkoutPartition(userID: String?) -> String? {
            guard let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userID.isEmpty else { return nil }
            return Self.partitionToken(for: userID)
        }

        private func ensureWorkoutImporter(
            repo: WorkoutsRepository,
            userID: String?,
            onIngest: (@Sendable () async -> Void)?
        ) async -> WorkoutHealthKitImporter? {
            guard let partition = authenticatedWorkoutPartition(userID: userID) else {
                return nil
            }
            let ownerUserID = Self.canonicalWorkoutOwner(userID)
            guard let directAuthIsCurrent = workoutDirectAuthLease(ownerUserID: ownerUserID) else {
                return nil
            }
            if let workoutHRBackfillOwnerUserID,
               workoutHRBackfillOwnerUserID != ownerUserID
            {
                await cancelWorkoutHRBackfillAndWait()
            }
            let existingLeaseIsCurrent = if let workoutImporter {
                await workoutImporter.hasCurrentLease()
            } else {
                true
            }
            if workoutImporterPartition != partition || !existingLeaseIsCurrent {
                // Invalidate synchronously before the first await so a user-A
                // query/mapping/upload cannot progress while replacement waits
                // for observer cleanup.
                workoutDirectLeaseRegistry.invalidate()
                await cancelWorkoutHRBackfillAndWait()
                await workoutImporter?.stopAndWaitUntilSettled()
                workoutImporter = nil
                workoutImporterLease = nil
                workoutHRBackfillSweep = nil
                workoutImporterPartition = partition
            }
            if workoutImporter == nil {
                let lease = workoutDirectLeaseRegistry.activate(
                    ownerUserID: ownerUserID,
                    authIsCurrent: directAuthIsCurrent
                )
                workoutImporterLease = lease
                workoutImporter = WorkoutHealthKitImporter(
                    store: store,
                    repo: repo,
                    userID: ownerUserID,
                    defaultsBox: workoutDefaultsBox,
                    lifecycleStore: workoutSyncDependencies.lifecycleStore,
                    anchoredQuerySource: workoutSyncDependencies.anchoredQuerySource,
                    lease: lease,
                    directDTOProvider: workoutSyncDependencies.directDTOProvider,
                    beforeSeriesFreeAnchorAdvance: { [weak self] count in
                        guard count > 0, let self else { return false }
                        return await rearmWorkoutHRBackfill(
                            for: ownerUserID,
                            trigger: .acceptedSeriesOmission,
                            lease: lease
                        )
                    }
                )
            }
            await workoutImporter?.setOnIngest(onIngest)
            return workoutImporter
        }

        /// Uses the same injected defaults store as the importer. Keeping the
        /// eligibility check and the eventual anchor read on one store avoids a
        /// false first-history launch in tests and in alternate app containers.
        nonisolated static func hasPersistedWorkoutAnchor(
            userID: String?,
            defaults: UserDefaults
        ) -> Bool {
            guard let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userID.isEmpty else { return false }
            let key = "hl.workout.hk.anchor." + partitionToken(for: userID)
            return defaults.object(forKey: key) != nil
        }

        /// Lazily builds (once per process) the GH #86 backfill sweep over the
        /// same `store` the importer uses.
        private var workoutHRBackfillSweep: WorkoutHRBackfillSweep?
        private var workoutHRBackfillTask: Task<WorkoutHRBackfillSweep.Outcome, Never>?
        private var workoutHRBackfillOwnerUserID: String?
        private var workoutHRBackfillGeneration = 0
        private var workoutHRBackfillMutationInProgress = false

        private func workoutHRBackfill(
            repo: WorkoutsRepository,
            userID: String?,
            lease: WorkoutImportLease
        ) -> WorkoutHRBackfillSweep {
            let ownerUserID = Self.canonicalWorkoutOwner(userID)
            if let workoutHRBackfillSweep,
               workoutHRBackfillOwnerUserID == ownerUserID
            {
                return workoutHRBackfillSweep
            }
            let leaseIsCurrent: @Sendable () -> Bool = { [lease] in lease.isCurrent }
            let sweep = WorkoutHRBackfillSweep(
                source: workoutSyncDependencies.historySource ?? HealthKitWorkoutHistorySource(
                    store: store,
                    leaseIsCurrent: leaseIsCurrent
                ),
                repo: repo,
                userID: ownerUserID,
                leaseIsCurrent: leaseIsCurrent,
                defaultsBox: workoutDefaultsBox
            )
            workoutHRBackfillSweep = sweep
            workoutHRBackfillOwnerUserID = ownerUserID
            return sweep
        }

        private func startWorkoutHRBackfillIfNeeded(
            repo: WorkoutsRepository,
            userID: String?,
            maxChunks: Int
        ) {
            let ownerUserID = Self.canonicalWorkoutOwner(userID)
            guard !ownerUserID.isEmpty,
                  !workoutHRBackfillMutationInProgress,
                  workoutHRBackfillTask == nil,
                  authenticatedWorkoutPartition(userID: ownerUserID) != nil,
                  let lease = workoutImporterLease,
                  lease.ownerUserID == ownerUserID,
                  lease.isCurrent else { return }
            let sweep = workoutHRBackfill(repo: repo, userID: ownerUserID, lease: lease)
            let generation = workoutHRBackfillGeneration
            workoutHRBackfillTask = Task(priority: .utility) { [weak self] in
                let outcome = await sweep.run(maxChunks: maxChunks)
                await self?.workoutHRBackfillDidFinish(generation: generation)
                return outcome
            }
        }

        private func runWorkoutHRBackfill(
            repo: WorkoutsRepository,
            userID: String?,
            maxChunks: Int
        ) async -> WorkoutHRBackfillSweep.Outcome {
            startWorkoutHRBackfillIfNeeded(repo: repo, userID: userID, maxChunks: maxChunks)
            guard let task = workoutHRBackfillTask else { return .cancelled }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func workoutHRBackfillDidFinish(generation: Int) {
            guard workoutHRBackfillGeneration == generation else { return }
            workoutHRBackfillTask = nil
        }

        private func cancelWorkoutHRBackfillAndWait() async {
            workoutHRBackfillGeneration &+= 1
            let task = workoutHRBackfillTask
            workoutHRBackfillTask = nil
            task?.cancel()
            if let task {
                _ = await task.value
            }
            workoutHRBackfillSweep = nil
            workoutHRBackfillOwnerUserID = nil
        }

        /// Durable pre-anchor barrier. Cancelling and awaiting the previous HR
        /// task prevents a stale in-flight cursor write from overwriting rearm.
        private func rearmWorkoutHRBackfill(
            for ownerUserID: String,
            trigger: WorkoutHRBackfillRearmTrigger,
            lease: WorkoutImportLease
        ) async -> Bool {
            guard !workoutHRBackfillMutationInProgress,
                  importerLeaseIsCurrent(lease, ownerUserID: ownerUserID) else { return false }
            workoutHRBackfillMutationInProgress = true
            defer { workoutHRBackfillMutationInProgress = false }
            await cancelWorkoutHRBackfillAndWait()
            guard importerLeaseIsCurrent(lease, ownerUserID: ownerUserID) else { return false }
            return workoutDefaultsBox.rearmBackfill(
                for: ownerUserID,
                trigger: trigger,
                leaseIsCurrent: { [lease] in lease.isCurrent }
            )
        }

        private func importerLeaseIsCurrent(
            _ lease: WorkoutImportLease,
            ownerUserID: String
        ) -> Bool {
            guard lease.ownerUserID == ownerUserID,
                  workoutImporterLease?.ownerUserID == ownerUserID,
                  workoutImporterLease?.authGeneration == lease.authGeneration else { return false }
            return lease.isCurrent
        }

        /// Captures the bearer generation as well as the canonical owner. A
        /// token rotation (including logout -> relogin as the same account)
        /// permanently invalidates the old direct importer instead of letting
        /// it become current again when only the user id happens to match.
        private func workoutDirectAuthLease(
            ownerUserID: String
        ) -> (@Sendable () -> Bool)? {
            guard Self.canonicalWorkoutOwner(
                keychain.getString(forKey: KeychainKey.userID)
            ) == ownerUserID,
                let capturedToken = keychain.getString(forKey: KeychainKey.authToken),
                !capturedToken.isEmpty else { return nil }
            return { [keychain] in
                Self.canonicalWorkoutOwner(
                    keychain.getString(forKey: KeychainKey.userID)
                ) == ownerUserID
                    && keychain.getString(forKey: KeychainKey.authToken) == capturedToken
            }
        }

        private nonisolated static func canonicalWorkoutOwner(_ userID: String?) -> String {
            userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// Stop + release the workout importer (logout).
        func stopWorkoutImport() async {
            workoutDirectLeaseRegistry.invalidate()
            await cancelWorkoutHRBackfillAndWait()
            await workoutImporter?.stopAndWaitUntilSettled()
            workoutImporter = nil
            workoutImporterLease = nil
            workoutImporterPartition = nil
            // GH #86 — drop the sweep too so a re-login rebuilds it against the
            // new user's partition.
            workoutHRBackfillSweep = nil
        }

        // MARK: - Heart-health + mobility EVENTS (W-HKREAD)

        /// Owns the categorical-EVENT importer (irregular-rhythm, high/low-HR,
        /// walking-steadiness, sleep-apnea, audio-exposure events). Always-on
        /// like the workout importer — these EVENT classes are in the always-on
        /// read set, not behind an opt-in toggle.
        private var eventImporter: HeartHealthEventImporter?
        private var eventImporterInputs: EventImportInputs?

        /// Start (or no-op if already running) the heart-health + mobility
        /// EVENT importer. Requires the uploader to be attached first
        /// (composition root calls ``setUploader(_:)`` before this); without it
        /// the start is a logged no-op so the importer can't silently drop
        /// events into a nil uploader.
        func startEventImport(userID: String?) async {
            eventImporterInputs = EventImportInputs(userID: userID)
            guard let uploader else {
                HLLog.healthKit.error("hk-event import skipped — uploader not attached yet")
                return
            }
            if eventImporter == nil {
                eventImporter = HeartHealthEventImporter(
                    store: store,
                    uploader: uploader,
                    userID: userID,
                    admission: healthSyncAdmission?.provider(for: .heartEvent),
                    cursors: healthSyncCursors,
                    retry: healthSyncRetryQueue
                )
            }
            await eventImporter?.start()
        }

        /// **Phase 07 / plan 07-07** — ensure the event importer exists, then
        /// force one bounded anchored read of every event type and report the
        /// worst-of disposition across them.
        ///
        /// Without an attached uploader there is nothing to post through, and
        /// the answer is `unsupported` — the same logged no-op `startEventImport`
        /// performs, with a word for it instead of a silent return.
        func refreshHeartEventImport(userID: String?) async -> HealthSyncImportOutcome {
            if eventImporter == nil {
                eventImporterInputs = EventImportInputs(userID: userID)
                guard let uploader else {
                    HLLog.healthKit.error("hk-event refresh skipped — uploader not attached yet")
                    return .unsupported
                }
                eventImporter = HeartHealthEventImporter(
                    store: store,
                    uploader: uploader,
                    userID: userID,
                    admission: healthSyncAdmission?.provider(for: .heartEvent),
                    cursors: healthSyncCursors,
                    retry: healthSyncRetryQueue
                )
                guard let disposition = await eventImporter?.start() else { return .unsupported }
                return HealthSyncImportOutcome(disposition: disposition)
            }
            guard let disposition = await eventImporter?.refresh() else { return .unsupported }
            return HealthSyncImportOutcome(disposition: disposition)
        }

        /// Stop + release the event importer (logout).
        func stopEventImport() async {
            await eventImporter?.stop()
            eventImporter = nil
            eventImporterInputs = nil
        }

        /// Reset every per-type event anchor, then stop. Called on logout /
        /// user-change so the next user starts from a clean anchor.
        func resetEventImport() async {
            await eventImporter?.resetAnchors()
            await eventImporter?.stop()
            eventImporter = nil
            eventImporterInputs = nil
        }

        /// Reset the per-user workout import anchor, then stop. Called on
        /// logout / user-change so the next user starts from a clean anchor.
        func resetWorkoutImport() async {
            workoutDirectLeaseRegistry.invalidate()
            await cancelWorkoutHRBackfillAndWait()
            await workoutImporter?.resetAnchorAndWaitUntilSettled()
            workoutImporter = nil
            workoutImporterLease = nil
            workoutImporterPartition = nil
        }

        // MARK: - Background-Delivery + Anchor-Sweep (post-W-A5 no-op shims)

        /// Pre-W-A5 this method registered an `HKObserverQuery` +
        /// `enableBackgroundDelivery` per legacy default type. Post-W-A5
        /// the SpeziHealthKit `CollectSamples` declarations in
        /// `HealthLogSpeziDelegate.configuration` own that responsibility
        /// — they call `HKHealthStore.startBackgroundDelivery` internally
        /// when `continueInBackground: true` is set. The shim stays so the
        /// `HealthKitServiceProtocol` + `AnyHealthKitWriter.activateBackground-
        /// Deliveries` contract continues to resolve from
        /// `BackgroundSyncCoordinator.activateHealthKitBackgroundDeliveries`
        /// (Foreground-bootstrap path) and the onboarding-permission
        /// re-authorization path in `HKReadinessStore.requestAuthorization`
        /// without breaking either call-site.
        public func startBackgroundDeliveries() async throws {
            // No-op — SpeziHealthKit owns the per-sample observer pipeline
            // post-W-A5. Kept callable for protocol conformance.
        }

        /// Pre-W-A5 this method ran a one-shot `HKAnchoredObjectQuery`
        /// sweep across every default background-delivery type as the
        /// `BGProcessingTask` wakeup payload. Post-W-A5 the SpeziHealthKit
        /// `CollectSamples` declarations own anchor-sweep responsibility
        /// — each collector internally manages its own
        /// `HKAnchoredObjectQuery` + anchor persistence (in
        /// SpeziLocalStorage). The BGProcessingTask still wakes the
        /// process for the "guaranteed sync even if HK didn't push us"
        /// guarantee, but the active work post-wake now lives in Spezi's
        /// automatic-with-background collectors which the system resumes
        /// as part of the same background-runtime tick.
        ///
        /// **W-B182 — no longer a no-op.** The `continueInBackground: false`
        /// collectors are now declared `start: .manual`
        /// (`HealthLogSpeziDelegate.configuration`), so they pull nothing until
        /// `HealthKit.triggerDataSourceCollection()` is actively called. This
        /// method drives that trigger via ``SpeziCollectionTrigger`` — re-arming
        /// (or re-firing) every manual collector from its persisted anchor on
        /// each `BGProcessingTask` wake (`BackgroundSyncCoordinator.handleBGTask`
        /// → `runBackgroundSyncPass`) and each manual "Jetzt syncen"
        /// (`HKReadinessStore.triggerManualSync` → `runBackgroundSyncPass`). The
        /// foreground `.active` path triggers it directly in `RootView`. This is
        /// the compensating mechanism for the W2 battery posture (the bulk of
        /// types arm no `.immediate` background delivery; this active pull keeps
        /// them constant instead).
        ///
        /// The six vital-sign collectors stay `start: .automatic` + background,
        /// so they are untouched by this trigger (they wake the app themselves).
        /// **Phase 07 / plan 07-09** — this arms the manual collectors and does
        /// not start a pass. It used to call `SpeziCollectionTrigger.trigger(source:
        /// .background)`, which both armed the collectors *and* ran a whole
        /// `.processing` pass — so a wake that also fanned out to statistics,
        /// ECG and workouts ran those twice. `AppContainer.runHealthSyncPass`
        /// now arms through here and then runs exactly one plan.
        public func runOneShotAnchorSweep() async {
            await SpeziCollectionTrigger.armManualCollectors()
        }

        // MARK: - Auth-Failure Mitigation (F8 hotfix v0.4.1.1)

        /// No-op post-W-A5. Pre-W-A5 this method cleared the in-memory
        /// "auth-disabled type identifiers" set that the legacy observer
        /// pipeline accumulated when an `HKObserverQuery` callback hit an
        /// `errorAuthorizationNotDetermined` / `errorAuthorizationDenied`
        /// error. With the observer pipeline gone the set is empty; the
        /// method survives because `HKReadinessStore.requestAuthorization`
        /// calls it after every successful re-authorization to keep the
        /// re-registration contract intact.
        public func resetAuthDisabledTypes() {
            // No-op — observer pipeline removed in W-A5.
        }

        // MARK: - Anchor key utilities (logout sweep + migrator lookup)

        //
        // `anchorDefaultsKeyPrefix`, `clearAnchors(for:in:)` and
        // `partitionToken(for:)` live in
        // `HealthKit/HealthKitService+AnchorKeys.swift` (file_length discipline
        // extract). The `defaults` stored property + `init` stay here.

        private let workoutDefaultsBox: WorkoutDefaultsBox
        private let workoutSyncDependencies: WorkoutSyncDependencies

        public init(
            store: HKHealthStore = HKHealthStore(),
            keychain: KeychainStoring,
            bundleID: String,
            defaults: sending UserDefaults = .standard,
            featureFlags: FeatureFlagsServicing? = nil
        ) {
            self.store = store
            self.keychain = keychain
            self.bundleID = bundleID
            workoutDefaultsBox = WorkoutDefaultsBox(defaults)
            self.featureFlags = featureFlags
            workoutSyncDependencies = WorkoutSyncDependencies()
        }

        init(
            store: HKHealthStore = HKHealthStore(),
            keychain: KeychainStoring,
            bundleID: String,
            defaultsSuiteName: String,
            featureFlags: FeatureFlagsServicing? = nil,
            workoutSyncDependencies: WorkoutSyncDependencies
        ) {
            self.store = store
            self.keychain = keychain
            self.bundleID = bundleID
            workoutDefaultsBox = WorkoutDefaultsBox(suiteName: defaultsSuiteName)
            self.featureFlags = featureFlags
            self.workoutSyncDependencies = workoutSyncDependencies
        }
    }

#endif
