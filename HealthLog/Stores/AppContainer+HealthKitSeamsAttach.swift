import Foundation

// MARK: - HealthKit sync seams + Spezi-uploader attach phase

extension AppContainer {
    /// Hands the opt-in importers' retry queue and account admission to
    /// `HealthKitService` AND wires the Spezi-side `HealthLogStandard` to the
    /// shared `MeasurementBatchUploader`.
    ///
    /// Static + non-isolated: everything it touches is `Sendable` (the uploader,
    /// the keychain) and the only side effects are the detached `attach*` hops
    /// the init body already performed.
    static func attachHealthKitSeamsAndSpeziUploader(
        healthKit: AnyHealthKitWriter?,
        uploader: MeasurementBatchUploader,
        keychain: KeychainStoring,
        deletionReconciler: (any MeasurementDeletionReconciler)?,
        retryQueue: OutboxQueue,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        aggregates: (hrBuckets: (any HealthKitHRBucketSyncing)?, dailyStats: (any HealthKitDailyStatsSyncing)?) = (nil, nil),
        serverFreshness: (@Sendable () async -> [MetricFreshness]?)? = nil,
        installsAppOwnedCollection: Bool = true,
        ingestModuleProbe: (@Sendable (ModuleKey) async -> Bool)? = nil
    ) {
        if let healthKit {
            // The account the opt-in State-of-Mind
            // importer sweeps under. Read fresh per sweep, exactly like the
            // sample path's, so a sweep that starts after a logout refuses
            // instead of running under the account that just went away.
            let moodAdmission = HealthSyncImporterAdmission.keychainBound(
                keychain: keychain,
                registry: authenticatedSessionRegistry
            )
            // The same admission serves the cycle and heart-event
            // importers, and the heart-event page additionally needs somewhere
            // durable to land when the server does not accept it.
            let importerRetryQueue = retryQueue
            Task.detached {
                await healthKit.attachHealthSyncRetryQueue(importerRetryQueue)
                // In the same task, before the admission starts importers, so
                // the event importer is never rebuilt behind a running one.
                await healthKit.attachIngestModuleProbe(ingestModuleProbe)
                await healthKit.attachHealthSyncAdmission(moodAdmission)
            }
        }
        // Hand the live MeasurementBatchUploader to the
        // Spezi-side HealthLogStandard so its
        // `handleNewSamples` callback can forward Steps + ActiveEnergy
        // observations through the same upload route the legacy
        // HealthKitService uses for everything else. No-op when Spezi is
        // not linked into the build configuration. The actual lookup +
        // attach lives in `AppContainer+SpeziStandard.swift`; we capture
        // values by-value here (the uploader is Sendable)
        // so the Task body doesn't need `self`-during-init access.
        #if canImport(Spezi) && canImport(SpeziHealthKit)
            let keychainForSpezi = keychain
            AppContainer.attachSpeziStandardUploader(
                uploader: uploader,
                userIDProvider: { keychainForSpezi.getString(forKey: KeychainKey.userID) },
                deletionReconciler: deletionReconciler,
                // The durable landing place for a page the
                // server did not terminally accept.
                retryQueue: retryQueue,
                // The per-sample path requests a bucket sweep whenever
                // it hands heart rate over; V1 — and a recent statistics sweep
                // whenever it hands a cumulative type over.
                hrBucketSync: aggregates.hrBuckets,
                dailyStatsSync: aggregates.dailyStats
            )
            // Install the app-owned sample collection. The
            // Spezi `CollectSamples` declarations it replaces were removed in the
            // same commit, so the old collectors are stopped by construction
            // before this one can start.
            // Not on a device that reads no HealthKit (the iPad): iCloud can
            // mirror Health data there, and nothing may collect or upload it.
            if installsAppOwnedCollection {
                AppContainer.installAppOwnedHealthCollection(
                    keychain: keychainForSpezi,
                    registry: authenticatedSessionRegistry,
                    uploader: uploader,
                    deliveryFollowUp: Self.deliveryFollowUp(aggregates),
                    serverFreshness: serverFreshness
                )
            }
        #else
            _ = aggregates
            _ = serverFreshness
        #endif
    }

    /// What a HealthKit delivery waits for before it hands back
    /// its completion handler: the sweeps its pages requested. Without the
    /// wait iOS may suspend the process the moment the handler returns, with
    /// the day totals still unsent.
    nonisolated static func deliveryFollowUp(
        _ aggregates: (hrBuckets: (any HealthKitHRBucketSyncing)?, dailyStats: (any HealthKitDailyStatsSyncing)?)
    ) -> @Sendable () async -> Void {
        { [hrBuckets = aggregates.hrBuckets, dailyStats = aggregates.dailyStats] in
            // Both run in their own tasks already; waiting one after the other
            // costs the longer of the two.
            await dailyStats?.awaitRequestedDailyStatsSweeps()
            await hrBuckets?.awaitHRBucketSweep()
        }
    }
}
