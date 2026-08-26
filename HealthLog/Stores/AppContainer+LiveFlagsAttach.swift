import Foundation

// MARK: - Live feature-flag + Spezi-uploader attach phase

extension AppContainer {
    /// Hands the live `FeatureFlagsServicing` to the legacy `HealthKitService`
    /// (so its per-sample observer can apply the Spezi-cutover filter) AND wires
    /// the Spezi-side `HealthLogStandard` to the shared `MeasurementBatchUploader`
    /// + flag reader. Construction VERBATIM from the prior inline `init` block —
    /// the same by-value captures + detached hops — so the move is
    /// behaviour-identical.
    ///
    /// Static + non-isolated: everything it touches is `Sendable` (the uploader,
    /// the live flag service, the keychain) and the only side effects are the
    /// detached `attach*` hops the init body already performed.
    static func attachLiveFlagsAndSpeziUploader(
        healthKit: AnyHealthKitWriter?,
        uploader: MeasurementBatchUploader,
        featureFlagsStore: FeatureFlagsStore,
        keychain: KeychainStoring,
        deletionReconciler: (any MeasurementDeletionReconciler)?,
        retryQueue: OutboxQueue,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry
    ) {
        // v0.5.5 W-A3: hand the live FeatureFlagsServicing to HealthKitService
        // so it can honour the `enableDailyStats` gate. (The former Spezi-cutover
        // skip-filter flags were removed in the v0162 cleanup once the legacy
        // per-sample observer pipeline was retired.)
        if let healthKit {
            let liveFlagsForHK = featureFlagsStore.liveService()
            // Phase 07 / plan 07-05 — the account the opt-in State-of-Mind
            // importer sweeps under. Read fresh per sweep, exactly like the
            // sample path's, so a sweep that starts after a logout refuses
            // instead of running under the account that just went away.
            let moodAdmission = HealthSyncImporterAdmission.keychainBound(
                keychain: keychain,
                registry: authenticatedSessionRegistry
            )
            // Plan 07-06 — the same admission serves the cycle and heart-event
            // importers, and the heart-event page additionally needs somewhere
            // durable to land when the server does not accept it.
            let importerRetryQueue = retryQueue
            Task.detached {
                await healthKit.attachFeatureFlags(liveFlagsForHK)
                await healthKit.attachHealthSyncRetryQueue(importerRetryQueue)
                await healthKit.attachHealthSyncAdmission(moodAdmission)
            }
        }
        // v0.5.5 W-A3: hand the live MeasurementBatchUploader + feature-flag
        // reader to the Spezi-side HealthLogStandard so its
        // `handleNewSamples` callback can forward Steps + ActiveEnergy
        // observations through the same upload route the legacy
        // HealthKitService uses for everything else. No-op when Spezi is
        // not linked into the build configuration. The actual lookup +
        // attach lives in `AppContainer+SpeziStandard.swift`; we capture
        // values by-value here (uploader + liveFlags are both Sendable)
        // so the Task body doesn't need `self`-during-init access.
        #if canImport(Spezi) && canImport(SpeziHealthKit)
            let liveFlagsForSpezi = featureFlagsStore.liveService()
            let keychainForSpezi = keychain
            AppContainer.attachSpeziStandardUploader(
                uploader: uploader,
                featureFlags: liveFlagsForSpezi,
                userIDProvider: { keychainForSpezi.getString(forKey: KeychainKey.userID) },
                deletionReconciler: deletionReconciler,
                // Phase 07 Wave 2 — the durable landing place for a page the
                // server did not terminally accept.
                retryQueue: retryQueue
            )
            // Phase 07 Wave 2 — install the app-owned sample collection. The
            // Spezi `CollectSamples` declarations it replaces were removed in the
            // same commit, so the old collectors are stopped by construction
            // before this one can start.
            AppContainer.installAppOwnedHealthCollection(
                keychain: keychainForSpezi,
                registry: authenticatedSessionRegistry,
                retryQueue: retryQueue
            )
        #endif
    }
}
