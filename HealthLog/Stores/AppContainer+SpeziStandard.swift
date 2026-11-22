#if canImport(Spezi) && canImport(SpeziHealthKit)
    @_spi(APISupport) import Spezi
    import SpeziHealthKit

    extension AppContainer {
        /// Resolve the running `HealthLogStandard` (booted by
        /// `HealthLogSpeziDelegate`) and hand it the live
        /// `MeasurementBatchUploader` so the `handleNewSamples` callback can route Steps + ActiveEnergy
        /// through the same upload path the legacy `HealthKitService`
        /// uses for everything else.
        ///
        /// **Why a Spezi-scoped extension instead of an inline call in
        /// `AppContainer.init`?** The standard is reachable through
        /// `SpeziAppDelegate.spezi` (a `@_spi(APISupport)` static), and
        /// the spezi-import that comes with it would leak into the main
        /// `AppContainer.swift` file. Isolating the attach logic here
        /// keeps the Spezi dependency surface explicit + grep-able and
        /// matches the existing `AppContainer+HealthKitStats.swift` /
        /// `AppContainer+AIWiring.swift` extension-file pattern.
        ///
        /// Declared `static` so the call-site can run BEFORE
        /// `AppContainer.init` finishes initializing all stored
        /// properties (Swift's flow-sensitive init analysis disallows
        /// `self`-method-calls until every stored property is set).
        /// Both inputs are Sendable so the Task body captures them
        /// safely; no `self` reference is needed.
        ///
        /// Idempotent — `HealthLogStandard.attachUploader` overwrites the
        /// stored references on every call.
        static func attachSpeziStandardUploader(
            uploader: MeasurementBatchUploader,
            userIDProvider: @escaping @Sendable () -> String?,
            deletionReconciler: (any MeasurementDeletionReconciler)?,
            retryQueue: (any HealthSyncBatchRetryEnqueuing)? = nil,
            hrBucketSync: (any HealthKitHRBucketSyncing)? = nil,
            dailyStatsSync: (any HealthKitDailyStatsSyncing)? = nil
        ) {
            // Every hand-off of heart rate requests the bucket sweep.
            var hrBucketKick: (@Sendable () -> Void)?
            if let hrBucketSync {
                hrBucketKick = { @Sendable in hrBucketSync.requestHRBucketSweep() }
            }
            // Every hand-off of a cumulative type requests the recent
            // statistics sweep, under the page's trigger.
            var dailyStatsKick: (@Sendable (SyncTrigger) async -> Void)?
            if let dailyStatsSync {
                dailyStatsKick = { @Sendable trigger in await dailyStatsSync.requestRecentDailyStatsSweep(trigger: trigger) }
            }
            Task { [hrBucketKick, dailyStatsKick] in
                guard let spezi = SpeziAppDelegate.spezi else {
                    HLLog.healthKit
                        .info("Spezi not booted — HealthLogStandard.attachUploader skipped")
                    return
                }
                // The `standard` slot on Spezi is `internal`; we get to it
                // via the public `module(_:)` lookup because every Standard
                // is auto-loaded as a Module under `.spezi` ownership.
                guard let standard = spezi.module(HealthLogStandard.self) else {
                    HLLog.healthKit
                        .info("HealthLogStandard not registered — attachUploader skipped")
                    return
                }
                // Hand the Standard the durable retry queue
                // instead of an anchor handle. A page the server did not
                // terminally accept becomes an owner-bound outbox row under a
                // derived idempotency key; rewinding SpeziHealthKit's anchor was
                // never able to recover such a page.
                // userIDProvider drives the HR-bucket cutover partition
                // so the per-sample HR gate reads
                // the same per-User cutover boundary the bucket sweep arms.
                // A row the server refuses is remembered in the skip
                // register before the cursor may pass it.
                await standard.attachUploader(
                    uploader,
                    userIDProvider: userIDProvider,
                    retryQueue: retryQueue,
                    skipRegister: .shared,
                    hrBucketKick: hrBucketKick,
                    dailyStatsKick: dailyStatsKick
                )
                // Hand the server-deletion reconciler
                // to the Standard so the collector's page deletions reach the
                // server delete-by-external-id (was a one-way mirror, so
                // orphaned server rows). nil-safe: unwired, a deletion waits
                // in the retry queue for the replay.
                await standard.attachDeletionReconciler(deletionReconciler)
                HLLog.healthKit.info("HealthLogStandard uploader attached")
            }
        }
    }
#endif
