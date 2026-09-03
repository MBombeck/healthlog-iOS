import Foundation

// Phase 07 Wave 4 — the composition half of the orchestrator.
//
// `HealthSyncOrchestrator` deliberately knows nothing about this app: it takes
// eleven `Sendable` closures and returns eleven named results. This file is the
// only place where those closures become HealthKit work, and the only place
// where "which account is this for" is asked on their behalf.
//
// It installs behind `AppOwnedHealthCollection`, the seam Plan 07-03 built for
// exactly this. Every existing pull trigger — the BGProcessing wake, the
// BGAppRefresh wake, the foreground revalidate, the manual "Jetzt syncen" and
// the silent push — already funnels through `SpeziCollectionTrigger`, so wiring
// the complete plan in edits no call site Plan 07-09 owns and adds no new direct
// trigger. What changes is what a trigger *reaches*: eleven named capabilities
// instead of the thirty-five sample types alone.
//
// Static and by-value, like `installAppOwnedHealthCollection`: every handle it
// takes is a `let` on the container and every one of them is `Sendable`, so the
// adapters need neither `self` nor an isolation hop to reach them.

extension AppContainer {
    /// Everything the eleven adapters need, in one value.
    ///
    /// A struct rather than eleven parameters because the alternative is a
    /// twelve-argument function that trips `function_parameter_count` and reads
    /// worse; the registry initializer is where the argument-per-capability
    /// discipline lives.
    struct HealthSyncCapabilityHandles: Sendable {
        let healthKit: (any AnyHealthKitWriter)?
        let ecgSync: (any EcgSyncing)?
        let dailyStats: (any HealthKitDailyStatsSyncing)?
        let hrBuckets: (any HealthKitHRBucketSyncing)?
        let nutrients: (any NutrientDailySyncing)?
        let medications: MedicationHealthSyncStore
        let moodRepo: MoodRepository
        let cycleRepo: CycleRepository
        /// **Plan 07-09** — the workout pass and the outbox drain are reached
        /// through the coordinator's own hooks rather than re-implemented here.
        /// Those hooks carry the authenticated-user resolution, the post-ingest
        /// revalidation and the reachability probe that
        /// `wireWorkoutBackgroundSync` / `wireOutboxBGDrainHook` own; a second,
        /// thinner call from the registry would have been the duplicate this
        /// plan exists to remove.
        let backgroundSync: BackgroundSyncCoordinator
        let keychain: KeychainStoring
        let sessionRegistry: AuthenticatedSessionLeaseRegistry
    }

    /// Collects the handles off the finished container and installs the pass.
    ///
    /// An instance method so `init` can call it as its last wiring step; every
    /// value it reads is an already-assigned `let`.
    @MainActor
    func installHealthSyncOrchestration() {
        let syncStateStore = serverStatsStores.syncState
        Self.installHealthSyncOrchestrator(
            handles: HealthSyncCapabilityHandles(
                healthKit: healthKit,
                ecgSync: ecgSync,
                dailyStats: healthKitDailyStatsSync,
                hrBuckets: healthKitHRBucketSync,
                nutrients: nutrientDailySync,
                medications: medicationHealthSyncStore,
                moodRepo: moodRepo,
                cycleRepo: cycleRepo,
                backgroundSync: backgroundSync,
                keychain: keychain,
                sessionRegistry: authenticatedSessionRegistry
            ),
            report: { pass in
                await Self.publishHealthSyncPass(pass, to: syncStateStore)
            }
        )
    }

    /// Builds the capability registry from the live services and installs one
    /// bounded orchestrated pass per trigger.
    @MainActor
    static func installHealthSyncOrchestrator(
        handles: HealthSyncCapabilityHandles,
        report: @escaping @Sendable (HealthSyncPassResult) async -> Void
    ) {
        let orchestrator = HealthSyncOrchestrator(
            registry: makeHealthSyncCapabilityRegistry(handles: handles),
            report: report
        )
        #if canImport(HealthKit) && canImport(SpeziHealthKit)
            AppOwnedHealthCollection.install { trigger, observedSource, isExpired in
                let pass = await orchestrator.run(
                    trigger,
                    observedSource: observedSource,
                    isExpired: isExpired
                )
                return pass.results.map(\.capability)
            }
        #else
            // No HealthKit in this configuration: the registry still names every
            // capability `unsupported`, and nothing installs a pass.
            _ = orchestrator
        #endif
    }

    /// The eleven adapters. Every argument is labelled, so a new
    /// `HealthSyncCapability` breaks this function until someone decides what it
    /// means here — which is the entire point of the registry being a compiler
    /// problem rather than a review problem.
    static func makeHealthSyncCapabilityRegistry(
        handles: HealthSyncCapabilityHandles
    ) -> HealthSyncCapabilityRegistry {
        let admission = HealthSyncImporterAdmission.keychainBound(
            keychain: handles.keychain,
            registry: handles.sessionRegistry
        )
        let keychain = handles.keychain
        let owner: @Sendable () -> String? = { keychain.getString(forKey: KeychainKey.userID) }

        return HealthSyncCapabilityRegistry(
            speziSampleCollection: { context in
                #if canImport(HealthKit) && canImport(SpeziHealthKit)
                    return await AppOwnedHealthCollection.runSampleCollection(context.trigger)
                #else
                    return .unsupported(.speziSampleCollection)
                #endif
            },
            workoutImport: { context in
                // Through the coordinator's own hook, so the authenticated-user
                // resolution and the post-ingest workout-list revalidation that
                // `wireWorkoutBackgroundSync` owns still apply — and so the
                // `WorkoutSyncDiagnosticContext` provenance still names the wake.
                let mode: WorkoutSyncPassMode = context.budget.incrementalOnly ? .incrementalOnly : .processing
                let didWork = await handles.backgroundSync.runWorkoutSync(
                    mode: mode,
                    source: workoutSource(for: context.trigger)
                )
                // `false` means "no authenticated user, no wired importer, or an
                // incremental wake with no anchor yet": nothing was lost and
                // nothing was proven, which is what `deferred` says.
                return didWork
                    ? .ran(.workoutImport)
                    : HealthSyncCapabilityResult(capability: .workoutImport, disposition: .deferred)
            },
            ecgUpload: { _ in
                // Deliberately not admission-annotated. Plan 07-06 kept the ECG
                // admission additive so ECG delivery survives an inert session
                // registry under the Phase-06 bearer capture; annotating it
                // `notAdmitted` would report a refusal that is not happening.
                guard let sync = handles.ecgSync else { return .disabled(.ecgUpload) }
                await sync.triggerEcgSync()
                return .ran(.ecgUpload)
            },
            dailyStatistics: { context in
                await admitted(.dailyStatistics, admission) {
                    guard let sync = handles.dailyStats else { return .unsupported(.dailyStatistics) }
                    // A short wake stays on today. Every other pass carries the
                    // v0.7.0 W-STEPS Layer-2 one-shot the removed anchor-sweep
                    // hook used to own: the first non-incremental sweep after
                    // onboarding honours the operator-chosen backfill window
                    // (`.allTime` → ~10y) so "Schritte alle Daten" has historical
                    // day-rows on day one; every later sweep is the cheap 7-day
                    // catch-up.
                    let lookback = context.budget.incrementalOnly
                        ? 1
                        : dailyStatsLookbackForNextSweep(keychain: keychain)
                    let completed = await sync.triggerDailyStatsSync(lookbackDays: lookback)
                    // v0.7.1 M-3 — burn the one-shot flag ONLY after the sync
                    // returns; Build 273 (A8) — and only if it COMPLETED. A
                    // held or killed sweep returned Void before, and the flag
                    // was burnt anyway.
                    if shouldBurnDailyStatsAllTimeBackfill(
                        incrementalOnly: context.budget.incrementalOnly, completed: completed
                    ) {
                        markDailyStatsAllTimeBackfillCompleted(keychain: keychain)
                    }
                    return .ran(.dailyStatistics)
                }
            },
            heartRateBuckets: { context in
                guard let sync = handles.hrBuckets else { return .unsupported(.heartRateBuckets) }
                await sync.triggerHRBucketSync(lookbackHours: context.budget.incrementalOnly ? 6 : 48)
                return .ran(.heartRateBuckets)
            },
            nutrientDailyTotals: { _ in
                guard let sync = handles.nutrients else { return .disabled(.nutrientDailyTotals) }
                await sync.triggerNutrientSync()
                return .ran(.nutrientDailyTotals)
            },
            moodStateOfMindImport: { _ in
                await admitted(.moodStateOfMindImport, admission) {
                    guard let writer = handles.healthKit else { return .unsupported(.moodStateOfMindImport) }
                    await writer.refreshMoodImport(repo: handles.moodRepo, userID: owner())
                    return .ran(.moodStateOfMindImport)
                }
            },
            appleMedicationImport: { _ in
                await admitted(.appleMedicationImport, admission) {
                    await handles.medications.triggerSyncIfEnabled()
                    return .ran(.appleMedicationImport)
                }
            },
            cycleImport: { _ in
                await admitted(.cycleImport, admission) {
                    guard let writer = handles.healthKit else { return .unsupported(.cycleImport) }
                    let outcome = await writer.refreshCycleImport(repo: handles.cycleRepo, userID: owner())
                    return HealthSyncCapabilityResult(capability: .cycleImport, disposition: outcome.disposition)
                }
            },
            heartHealthEvents: { _ in
                await admitted(.heartHealthEvents, admission) {
                    guard let writer = handles.healthKit else { return .unsupported(.heartHealthEvents) }
                    let outcome = await writer.refreshEventImport(userID: owner())
                    return HealthSyncCapabilityResult(
                        capability: .heartHealthEvents,
                        disposition: outcome.disposition
                    )
                }
            },
            outboxDrain: { _ in
                // The coordinator's probe-gated drain, which is itself the
                // reachability-gated `OutboxReplayService.runOnce()` that
                // `wireOutboxBGDrainHook` installs. `false` means no drain is
                // wired at all; a wake on a captive-portal Wi-Fi is not a failed
                // drain either way — the rows are intact and the next reachable
                // moment replays them.
                let didDrain = await handles.backgroundSync.runOutboxDrain()
                return didDrain
                    ? .ran(.outboxDrain)
                    : HealthSyncCapabilityResult(capability: .outboxDrain, disposition: .deferred)
            }
        )
    }

    /// The diagnostics provenance a workout pass carries, per wake.
    ///
    /// Named rather than defaulted: `HKSyncDiagnostics` reports which wake
    /// delivered a workout, and "manual" for a BGProcessing grant would make the
    /// background-delivery evidence unreadable.
    private static func workoutSource(for trigger: HealthSyncTrigger) -> WorkoutSyncSource {
        switch trigger {
        case .processing: .processing
        case .appRefresh: .appRefresh
        case .silentPush: .push
        case .observer: .observer
        case .manual: .manual
        case .coldActivation, .postAuthentication, .foreground, .accountTeardown: .foreground
        }
    }

    /// Publishes one finished pass to the canonical sync-status store.
    ///
    /// Deliberately not a new banner or spinner: the app already has one place
    /// that answers "what is the state of syncing", and a second one would be a
    /// second thing to keep true.
    @MainActor
    static func publishHealthSyncPass(_ pass: HealthSyncPassResult, to store: SyncStateStore) {
        let snapshot = pass.publicSnapshot
        store.noteHealthSyncPass(snapshot)
        HKSyncDiagnostics.shared.recordHealthSyncPass(snapshot)
        // Every interpolated value is a fixed enum case name or a count — no
        // sample, value, identifier, or account. `.public` is correct here.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info(
            """
            HK-SYNC pass \(snapshot.trigger, privacy: .public) — \
            complete=\(snapshot.isComplete, privacy: .public) \
            held=\(snapshot.heldItemCount, privacy: .public) \
            omitted=\(snapshot.omittedCapabilities.count, privacy: .public) \
            notAdmitted=\(snapshot.capabilitiesRefusedForMissingAdmission.count, privacy: .public)
            """
        )
    }

    /// Runs a capability and tells the truth about admission.
    ///
    /// The body runs either way — every admission-gated importer already refuses
    /// on its own and refusing twice would change nothing about what the app
    /// does. What this adds is the *word*: when the account could not be admitted
    /// and the capability did not nevertheless succeed, the result carries
    /// `notAdmitted` instead of the indistinguishable "ran, nothing to do".
    ///
    /// That distinction is not theoretical. Nothing in production activates
    /// `authenticatedSessionRegistry` today (see
    /// ``HealthSyncCompositionPlan/installedActivatesSessionRegistry``),
    /// so on a device every admission-gated capability here refuses — and before
    /// this annotation existed, the pass looked exactly like a quiet success.
    private static func admitted(
        _ capability: HealthSyncCapability,
        _ admission: HealthSyncImporterAdmission,
        _ body: @Sendable () async -> HealthSyncCapabilityResult
    ) async -> HealthSyncCapabilityResult {
        let refusal = admission.refusal(for: capability.source)
        let result = await body()
        guard let refusal, result.disposition != .succeeded, result.disposition != .unsupported else {
            return result
        }
        return .refused(capability, refusal)
    }
}
