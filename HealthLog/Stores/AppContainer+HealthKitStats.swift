import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

// MARK: - V0.5.2 N4 — HK-STATS-Wiring

extension AppContainer {
    // **Phase 07 / plan 07-09** — `wireEcgBackgroundSync` is gone. It attached a
    // second ECG hook to the BGProcessing wake, and the orchestrated pass already
    // runs `ecgUpload` as one of its eleven capabilities against the same
    // coordinator, which self-gates on the device-local opt-in, authentication
    // and the server-owned `insights` module. Two hooks, one sweep, one
    // coalescer: the second call was work the first had already done.

    /// Wires the direct workout importer from authenticated composition-root
    /// state. Every await is bracketed by an auth/user check so logout, a 401,
    /// or an in-process account switch cannot continue UI reconciliation for
    /// the previous partition.
    @MainActor
    static func wireWorkoutBackgroundSync(
        backgroundSync: BackgroundSyncCoordinator,
        healthKit: AnyHealthKitWriter?,
        repository: WorkoutsRepository,
        store: WorkoutsStore,
        authStore: AuthStore,
        keychain: KeychainStoring
    ) {
        guard let healthKit else { return }
        backgroundSync.attachWorkoutSyncHook { mode in
            guard !Task.isCancelled,
                  let userID = await authenticatedWorkoutUserID(
                      authStore: authStore,
                      keychain: keychain
                  ) else { return false }

            let didRun = await healthKit.runWorkoutSyncPass(
                repo: repository,
                userID: userID,
                mode: mode,
                onIngest: { @Sendable in
                    guard !Task.isCancelled,
                          await authenticatedWorkoutUserID(
                              authStore: authStore,
                              keychain: keychain,
                              matching: userID
                          ) != nil else { return }
                    await store.revalidateIfStale()
                }
            )

            guard !Task.isCancelled,
                  await authenticatedWorkoutUserID(
                      authStore: authStore,
                      keychain: keychain,
                      matching: userID
                  ) != nil else { return false }
            return didRun
        }
    }

    @MainActor
    private static func authenticatedWorkoutUserID(
        authStore: AuthStore,
        keychain: KeychainStoring,
        matching expectedUserID: String? = nil
    ) -> String? {
        guard case .authenticated = authStore.phase,
              keychain.getString(forKey: KeychainKey.authToken) != nil,
              let userID = keychain.getString(forKey: KeychainKey.userID),
              !userID.isEmpty,
              expectedUserID == nil || expectedUserID == userID else { return nil }
        return userID
    }

    /// Instanziiert den `HealthKitStatisticsSyncCoordinator` zusammen mit
    /// seinen Dependencies (`HealthKitDailyStatsCache`, `HealthKitStatisticsService`,
    /// `LiveFeatureFlagsService`). Returnt `nil`, wenn `healthKit == nil`
    /// (Non-iOS-Build, Tests ohne HK-Stub) oder HealthKit am Build-Site
    /// nicht verfuegbar ist.
    ///
    /// **Recovery-Pfad:** Bei korruptem oder unbau-baren SwiftData-Store
    /// faellt die Factory auf einen In-Memory-Store zurueck — die HK-STATS-
    /// Pipeline laeuft dann ohne Restart-Survival, das ist immer noch
    /// besser als ein Crash beim Cold-Start oder eine Steps-Tile mit
    /// "37 Schritte" weil der Coord nie startet. Bei totalem Versagen
    /// (auch In-Memory-Store laesst sich nicht bauen) returnt die Factory
    /// `nil` und die HK-STATS-Pipeline bleibt dunkel.
    /// Composition-helper: instanziiert den Stats-Coordinator und haengt seinen
    /// Trigger an den `BackgroundSyncCoordinator` — sodass nach jedem
    /// BG-Activate + BGTask-Wakeup die Tagestotale fuer Steps + die anderen 4
    /// kumulativen HK-Types an den Server gehen.
    ///
    /// Ohne diesen Wiring-Pfad bleiben die per-Sample-gefilterten Cumulative-
    /// Types unhochgeladen (wenn `enableDailyStats` ON ist, Default ON) →
    /// Dashboard zeigt das letzte Einzelsample ("37 Schritte") statt das
    /// Day-Cumulative-Total. Operator-reported Regression auf v0.5.1.
    static func wireHealthKitDailyStats(
        healthKit: AnyHealthKitWriter?,
        uploader: MeasurementBatchUploader,
        featureFlagsStore: FeatureFlagsStore,
        backgroundSync: BackgroundSyncCoordinator,
        swr: SWRCoordinator,
        keychain: KeychainStoring,
        registry: AuthenticatedSessionLeaseRegistry,
        retryQueue: OutboxQueue?,
        hrBucketSync: HealthKitHRBucketSyncing? = nil,
        nutrientSync: NutrientDailySyncing? = nil
    ) -> HealthKitDailyStatsSyncing? {
        let stats = makeHealthKitDailyStatsSync(
            healthKit: healthKit,
            uploader: uploader,
            featureFlagsStore: featureFlagsStore,
            keychain: keychain,
            registry: registry,
            retryQueue: retryQueue
        )
        // **Phase 07 / plan 07-09 — the bundled anchor-sweep hook is gone.**
        //
        // It fired daily statistics, HR buckets and nutrients as one closure on
        // every BG-activate and BGTask wake. Those are three capabilities in the
        // Phase-07 plan, each of which the orchestrated pass already ran, so the
        // hook was the third of the phase's duplicate fan-outs. What it carried
        // that the plan did not — the v0.7.0 W-STEPS Layer-2 one-shot that honours
        // the operator-chosen backfill window on the first non-incremental sweep,
        // and the v0.7.1 M-3 rule that the flag is burnt only *after* the sync
        // returns — moved into the `dailyStatistics` adapter in
        // `AppContainer+HealthSyncOrchestrator.swift`, unchanged in either
        // respect. `dailyStatsLookbackForNextSweep` and
        // `markDailyStatsAllTimeBackfillCompleted` are still the only two
        // functions that decide it.

        // V0.12 W8-4 — wire the BGTask cache-sweep hook here (both the SWR + the
        // daily-stats sweepers are available). Impl in AppContainer+Foreground.
        wireCacheSweepHook(backgroundSync: backgroundSync, swr: swr, dailyStats: stats)
        return stats
    }

    /// The three HK-stats coordinators built as one ordered cluster.
    struct HealthKitStatsCluster {
        let hrBucket: HealthKitHRBucketSyncing?
        let dailyStats: HealthKitDailyStatsSyncing?
        let liveToday: LiveHealthKitTodayStore
        let nutrient: NutrientDailySyncing? // GH #48
    }

    /// Builds the three HK-stats coordinators as one cluster — preserving the
    /// init's order: the HR-bucket sync is built FIRST so it can ride the same
    /// anchor-sweep hook the daily-stats sync arms (single hook slot → both
    /// triggered in one closure), then the live-today step store wraps the
    /// daily-stats reader in a `Sendable` closure (bug-c10-ios-direct). Pure
    /// move of the inline init block; behaviour-identical.
    static func makeHealthKitStatsCluster(
        healthKit: AnyHealthKitWriter?,
        api: APIClientProtocol,
        uploader: MeasurementBatchUploader,
        featureFlagsStore: FeatureFlagsStore,
        backgroundSync: BackgroundSyncCoordinator,
        swr: SWRCoordinator,
        keychain: KeychainStoring,
        registry: AuthenticatedSessionLeaseRegistry,
        retryQueue: OutboxQueue?,
        moduleGate: ModuleGate
    ) -> HealthKitStatsCluster {
        let hrBucketSync = makeHRBucketSync(
            healthKit: healthKit,
            uploader: uploader,
            featureFlagsStore: featureFlagsStore,
            keychain: keychain
        )
        // GH #48 — built BEFORE `wireHealthKitDailyStats` so it can ride the same
        // anchor-sweep hook the daily-stats sync arms (single hook slot).
        let nutrientSync = makeNutrientDailySync(
            healthKit: healthKit,
            api: api,
            keychain: keychain,
            moduleGate: moduleGate
        )
        let dailyStats = wireHealthKitDailyStats(
            healthKit: healthKit,
            uploader: uploader,
            featureFlagsStore: featureFlagsStore,
            backgroundSync: backgroundSync,
            swr: swr,
            keychain: keychain,
            registry: registry,
            retryQueue: retryQueue,
            hrBucketSync: hrBucketSync,
            nutrientSync: nutrientSync
        ) // V0.5.2 N4 + v0.7.0 W-STEPS Layer 2; W8-4 cache-sweep wired inside
        let liveToday = LiveHealthKitTodayStore(
            reader: { [weak dailyStats] in
                await dailyStats?.liveTodayStepCount()
            }
        )
        return HealthKitStatsCluster(
            hrBucket: hrBucketSync,
            dailyStats: dailyStats,
            liveToday: liveToday,
            nutrient: nutrientSync
        )
    }

    /// GH #48 — builds the nutrient daily-totals coordinator. Returns `nil` when
    /// `healthKit == nil` (non-iOS build / HK-less test host) so the slot stays
    /// inert. The `nutrients` module gate is read live off the main actor via a
    /// closure so the actor stays free of the `@MainActor` `ModuleGate`.
    static func makeNutrientDailySync(
        healthKit: AnyHealthKitWriter?,
        api: APIClientProtocol,
        keychain: KeychainStoring,
        moduleGate: ModuleGate
    ) -> NutrientDailySyncing? {
        #if canImport(HealthKit)
            guard healthKit != nil else { return nil }
            return NutrientDailySyncCoordinator(
                statisticsService: HealthKitStatisticsService(),
                api: api,
                keychain: keychain,
                isModuleEnabled: { [moduleGate] in
                    await MainActor.run { moduleGate.isEnabled(.nutrients) }
                }
            )
        #else
            _ = healthKit
            _ = api
            _ = keychain
            _ = moduleGate
            return nil
        #endif
    }

    /// Picks the `lookbackDays` for the next daily-stats sweep.
    ///
    /// Returns the window-derived span (`.allTime → 3650`, `.oneYear → 365`,
    /// `.ninetyDays → 90`, …) while the one-shot all-time backfill is still
    /// pending — the first sweep after onboarding — gated behind the per-User
    /// `dailyStatsAllTimeBackfillCompleted` flag. Once the flag is set (see
    /// ``markDailyStatsAllTimeBackfillCompleted(keychain:defaults:)``) every
    /// later sweep returns the incremental `7`-day catch-up.
    ///
    /// **v0.7.1 M-3 — pure read.** This used to `set(true)` the completion
    /// flag as a side-effect when it handed out the wide span, which burned
    /// the one-shot *before* the sweep had actually run: a sync that threw or
    /// a BGTask killed mid-flight left the flag set with no historical day-rows
    /// written, and the expensive backfill never retried. The mutation now
    /// lives in `markDailyStatsAllTimeBackfillCompleted`, called by the sweep
    /// hook only after `triggerDailyStatsSync` returns. This accessor is now a
    /// pure query — repeated calls return the same span until the work
    /// completes and the flag is set.
    ///
    /// Falls back to `incrementalLookbackDays` when no window has been
    /// persisted yet (the live HK sync still backfills via the Spezi
    /// collector's `timeRange` — this path only widens the *server* day-row
    /// snapshot for the chart-detail `.all` segment).
    ///
    /// `nonisolated` + `defaults`-injectable so the `@Sendable` sweep hook can
    /// call it off the main actor and unit tests can pin the gate behaviour
    /// against an isolated `UserDefaults` suite.
    nonisolated static let incrementalLookbackDays = 7
    nonisolated static let allTimeLookbackDays = 3650
    nonisolated static let dailyStatsAllTimeBackfillFlagPrefix = "hl.healthkit.dailyStatsAllTimeBackfillCompleted."

    nonisolated static func dailyStatsLookbackForNextSweep(
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) -> Int {
        let userID = keychain.getString(forKey: KeychainKey.userID)
        let flagKey = dailyStatsAllTimeBackfillFlagPrefix
            + HealthKitBackfillWindowStore.partitionToken(for: userID)
        guard !defaults.bool(forKey: flagKey) else {
            return incrementalLookbackDays
        }
        guard let window = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults) else {
            return incrementalLookbackDays
        }
        return lookbackDays(for: window)
    }

    /// Marks the per-User one-shot all-time daily-stats backfill as completed
    /// so subsequent sweeps return the incremental window. Called by the sweep
    /// hook **after** `triggerDailyStatsSync` returns (v0.7.1 M-3), so a failed
    /// or interrupted first sweep re-arms on the next launch. Idempotent.
    nonisolated static func markDailyStatsAllTimeBackfillCompleted(
        keychain: KeychainStoring,
        defaults: UserDefaults = .standard
    ) {
        let userID = keychain.getString(forKey: KeychainKey.userID)
        let flagKey = dailyStatsAllTimeBackfillFlagPrefix
            + HealthKitBackfillWindowStore.partitionToken(for: userID)
        defaults.set(true, forKey: flagKey)
    }

    /// Translates a persisted `HealthKitBackfillWindow` into the
    /// `sync(lookbackDays:)` span. `.allTime` maps to ~10 years rather than a
    /// literal `.distantPast` so the `HKStatisticsCollectionQuery` enumerates
    /// a bounded (still system-cached) bucket set instead of iterating from
    /// year 1.
    nonisolated static func lookbackDays(for window: HealthKitBackfillWindow) -> Int {
        switch window {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .oneYear: 365
        case .allTime: allTimeLookbackDays
        }
    }

    /// W-HR-BUCKET-UPLOAD / GH #34 — builds the 10-minute-HR-bucket coordinator.
    /// Returns `nil` when `healthKit == nil` (non-iOS build / HK-less test host)
    /// so the slot stays inert. The coordinator shares the live
    /// `MeasurementBatchUploader` (idempotency-key + throttle + backoff reuse)
    /// and reads the standalone predicate live off the main actor.
    static func makeHRBucketSync(
        healthKit: AnyHealthKitWriter?,
        uploader: MeasurementBatchUploader,
        featureFlagsStore: FeatureFlagsStore,
        keychain: KeychainStoring
    ) -> HealthKitHRBucketSyncing? {
        #if canImport(HealthKit)
            guard healthKit != nil else { return nil }
            return HealthKitHRBucketSyncCoordinator(
                service: HealthKitHRBucketService(),
                uploader: uploader,
                featureFlags: featureFlagsStore.liveService(),
                keychain: keychain,
                isStandalone: standaloneModePredicate()
            )
        #else
            _ = healthKit
            _ = uploader
            _ = featureFlagsStore
            _ = keychain
            return nil
        #endif
    }

    /// GH #47 — builds the iOS 26+ HealthKit medications reader. Returns `nil`
    /// below iOS 26 or on a non-HealthKit build so `MedicationHealthSyncStore`
    /// reports `isAvailable == false` and never offers the toggle.
    static func makeAppleHealthMedicationReader() -> AppleHealthMedicationReading? {
        #if canImport(HealthKit)
            if #available(iOS 26.0, *) {
                return AppleHealthMedicationReader()
            }
            return nil
        #else
            return nil
        #endif
    }

    static func makeHealthKitDailyStatsSync(
        healthKit: AnyHealthKitWriter?,
        uploader: MeasurementBatchUploader,
        featureFlagsStore: FeatureFlagsStore,
        keychain: KeychainStoring? = nil,
        registry: AuthenticatedSessionLeaseRegistry? = nil,
        retryQueue: OutboxQueue? = nil
    ) -> HealthKitDailyStatsSyncing? {
        #if canImport(HealthKit)
            guard healthKit != nil else { return nil }
            let liveFlags = featureFlagsStore.liveService()
            // Phase 07 / Plan 07-04 — the admission, evaluated fresh per sweep.
            // Same shape as `installAppOwnedHealthCollection`: the signed-in user
            // and the bearer paired with it, read once and pinned for the pass.
            // Without both, the sweep refuses rather than syncing under whoever
            // signed in last.
            let admission: (@Sendable () throws -> HealthSyncAuthenticatedLease)? = if let keychain, let registry {
                {
                    try HealthSyncAuthenticatedLease.admit(
                        from: registry,
                        ownerID: keychain.getString(forKey: KeychainKey.userID) ?? "",
                        source: .dailyStatistics,
                        bearerProvider: { keychain.getString(forKey: KeychainKey.authToken) }
                    )
                }
            } else {
                nil
            }
            // audit P-1 — defer the SwiftData cache open off the cold-launch
            // tick. Unlike the Outbox (BGTaskScheduler.register must run in
            // `applicationDidFinishLaunching`), the daily-stats cache has no
            // launch-tick coupling, so the coordinator holds a pending
            // open-task and resolves it lazily on the first sync / sweep.
            // Mirrors `SWRCoordinator(cacheTask:)`. Savings: ~30-80 ms cold.
            // The recovery ladder (persistent → non-trapping in-memory floor)
            // now lives in `HealthKitDailyStatsCache.makeWithRecovery()`.
            let cacheTask = HealthKitDailyStatsCache.makeWithRecoveryTask()
            let stats = HealthKitStatisticsService()
            return HealthKitStatisticsSyncCoordinator(
                statisticsService: stats,
                cacheTask: cacheTask,
                uploader: uploader,
                featureFlags: liveFlags,
                admission: admission,
                retry: retryQueue
            )
        #else
            _ = healthKit
            _ = uploader
            _ = featureFlagsStore
            _ = keychain
            _ = registry
            _ = retryQueue
            return nil
        #endif
    }
}
