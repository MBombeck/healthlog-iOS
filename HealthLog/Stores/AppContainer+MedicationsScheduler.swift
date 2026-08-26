#if canImport(Spezi) && canImport(SpeziScheduler)
    import Foundation
    @_spi(APISupport) import Spezi
    import SpeziScheduler

    extension AppContainer {
        /// Resolve the running `MedicationsSchedulerModule` (registered
        /// by `HealthLogSpeziDelegate.configuration`) and trigger a
        /// reconcile pass from the supplied medication snapshot.
        ///
        /// **Why a Spezi-scoped extension instead of an inline call in
        /// `AppContainer.init`?** Mirrors the existing
        /// `AppContainer+SpeziStandard.swift` rationale — the
        /// `@_spi(APISupport) import Spezi` + the SpeziScheduler product
        /// would leak into the main `AppContainer.swift` file. Isolating
        /// the attach logic here keeps the SpeziScheduler dependency
        /// surface explicit + grep-able + parallel to the
        /// `attachSpeziStandardUploader` /
        /// `resolveSpeziLLMIfAvailable` patterns.
        ///
        /// **When it's called:** every `MedicationsStore.load()` ends
        /// with a `.fresh(value)` arm that hands us the new medication
        /// array; we hop here to project the array onto Spezi `Task`
        /// records. The reconcile is idempotent — a re-run with the
        /// same medications is a no-op at the SwiftData layer (Spezi's
        /// version-check skips unchanged tasks).
        ///
        /// Declared `static` so it can run from inside the
        /// `MedicationsStore.load()` completion path without
        /// container-self capture; the lookup walks
        /// `SpeziAppDelegate.spezi` directly.
        static func reconcileMedicationsScheduler(medications: [Medication]) {
            _Concurrency.Task { @MainActor in
                guard let spezi = SpeziAppDelegate.spezi else {
                    HLLog.notifications
                        .info("Spezi not booted — MedicationsSchedulerModule reconcile skipped")
                    return
                }
                guard let module = spezi.module(MedicationsSchedulerModule.self) else {
                    HLLog.notifications
                        .info("MedicationsSchedulerModule not registered — reconcile skipped")
                    return
                }
                module.reconcile(medications: medications)

                // v0.15.5 AUD-1 F8 (defense in depth) — force a SpeziScheduler
                // notification refresh after every reconcile. The reconcile
                // above re-arms one-shot occurrences (monthly / everyNWeeks>1 /
                // rolling / cyclic) and SpeziScheduler auto-schedules a refresh
                // when a *task version changes*, but an unchanged daily/weekly
                // task set does NOT re-trigger a refresh on its own — so a queue
                // that has simply drained below the horizon would not be topped
                // up by the reconcile alone. This explicit call tops the pending
                // queue up on every reconcile.
                //
                // Why this matters for the background path: the guaranteed-sync
                // `BGProcessingTask` (`dev.healthlog.app.healthkit-sync`,
                // `BackgroundSyncCoordinator`) runs `MedicationsStore.load(force:)`
                // → `reconcileSpeziSchedulerIfAvailable()` → here. SpeziScheduler's
                // OWN `BGAppRefreshTask` (enabled by the F1 `fetch` mode) is the
                // primary top-up, but Background App Refresh can be disabled by
                // the user; this gives a second, independent re-arm riding the
                // app's HK-sync wakeup which is known to run.
                //
                // `scheduleNotificationsUpdate` is coalesced upstream
                // (`queuedForNextTick`), so calling it on every reconcile —
                // including idempotent foreground re-runs — is cheap.
                if let scheduler = spezi.module(Scheduler.self) {
                    scheduler.manuallyScheduleNotificationRefresh()
                }
            }
        }

        /// v0.6.0.7 Spezi Phase E — mark every Spezi `Event` for the
        /// supplied medication as completed inside a ±1h window around
        /// `scheduledFor`. Called from `NotificationService.dispatch-
        /// Action` after a successful server-mark-intake POST, so the
        /// SpeziScheduler `Outcome` mirror reflects the user's action
        /// and the next scheduling pass does not re-queue a banner for
        /// the same dose.
        ///
        /// Errors are logged + swallowed because the local Spezi mirror
        /// is non-authoritative — the server-mark-intake already
        /// succeeded; if Spezi fails to update its local outcome the
        /// worst case is a duplicate banner for the same dose on the
        /// next BGAppRefresh, not data loss.
        static func completeSpeziEventForMedication(
            medicationId: String,
            scheduledFor: Date
        ) {
            _Concurrency.Task { @MainActor in
                guard let spezi = SpeziAppDelegate.spezi,
                      let scheduler = spezi.module(Scheduler.self) else
                {
                    return
                }
                // Window the query to ±1h around the scheduled instant
                // — covers the typical operator workflow (banner fires
                // at 09:00, user taps "Genommen" at 09:25). Spezi
                // matches events whose `occurrence.start` lies inside
                // the range; we walk the matches and complete every
                // task whose id is a medication task for this id.
                let window: TimeInterval = 60 * 60
                let lowerBound = scheduledFor.addingTimeInterval(-window)
                let upperBound = scheduledFor.addingTimeInterval(window)
                do {
                    let events = try scheduler.queryEvents(for: lowerBound ..< upperBound)
                    var completed = 0
                    for event in events {
                        guard let taskMedID = MedicationsSchedulerModule
                            .medicationId(fromTaskID: event.task.id),
                            taskMedID == medicationId,
                            !event.isCompleted else
                        {
                            continue
                        }
                        do {
                            try event.complete()
                            completed += 1
                        } catch {
                            HLLog.notifications.error(
                                "completeSpeziEventForMedication: event.complete failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                            )
                        }
                    }
                    if completed > 0 {
                        HLLog.notifications.info(
                            "completeSpeziEventForMedication: completed \(completed) event(s) medicationId=\(medicationId, privacy: .public)"
                        )
                    }
                } catch {
                    HLLog.notifications.error(
                        "completeSpeziEventForMedication: queryEvents failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }
        }
    }
#endif
