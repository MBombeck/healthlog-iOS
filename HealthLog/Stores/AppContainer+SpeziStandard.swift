#if canImport(Spezi) && canImport(SpeziHealthKit)
    @_spi(APISupport) import Spezi
    import SpeziHealthKit

    extension AppContainer {
        /// Resolve the running `HealthLogStandard` (booted by
        /// `HealthLogSpeziDelegate`) and hand it the live
        /// `MeasurementBatchUploader` + feature-flag reader so the
        /// `handleNewSamples` callback can route Steps + ActiveEnergy
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
        /// `AppContainer+FeatureFlags.swift` extension-file pattern.
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
            featureFlags: any FeatureFlagsServicing,
            userIDProvider: @escaping @Sendable () -> String?,
            deletionReconciler: (any MeasurementDeletionReconciler)?,
            retryQueue: (any HealthSyncBatchRetryEnqueuing)? = nil
        ) {
            Task {
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
                // Phase 07 Wave 2 — hand the Standard the durable retry queue
                // instead of an anchor handle. A page the server did not
                // terminally accept becomes an owner-bound outbox row under a
                // derived idempotency key; rewinding SpeziHealthKit's anchor was
                // never able to recover such a page.
                // userIDProvider drives the HR-bucket cutover partition
                // (W-HR-BUCKET-UPLOAD / GH #34) so the per-sample HR gate reads
                // the same per-User cutover boundary the bucket sweep arms.
                await standard.attachUploader(
                    uploader,
                    featureFlags: featureFlags,
                    userIDProvider: userIDProvider,
                    retryQueue: retryQueue
                )
                // A360-5 M-1 — hand the server-deletion reconciler to the
                // Standard so `handleDeletedObjects` can mirror Apple-Health
                // deletions to a server delete-by-external-id (was a one-way
                // mirror → orphaned server rows). nil-safe (the Standard keeps
                // its no-op when unwired).
                await standard.attachDeletionReconciler(deletionReconciler)
                HLLog.healthKit.info("HealthLogStandard uploader attached")
            }
        }
    }
#endif
