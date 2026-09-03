// swiftformat:disable opaqueGenericParameters
// The `Sample` generic on `handleNewSamples` / `handleDeletedObjects` must
// stay named (not `some`) because `SampleType<Sample>` references it in the
// second parameter — SwiftFormat's `opaqueGenericParameters` rule is disabled
// for the whole file to keep the protocol witness shape intact.

#if canImport(SpeziHealthKit)
    import HealthKit
    import Spezi
    import SpeziHealthKit

    #if canImport(UIKit)
        import UIKit // #66 P0.1 — observer-wake background/foreground gate
    #endif
    #if canImport(SpeziScheduler) && canImport(UserNotifications)
        // Module-qualified import — the `Task` symbol on the SpeziScheduler
        // module collides with Swift's `_Concurrency.Task`; qualifying here
        // keeps the rest of this file's `Task { … }` closures (none today,
        // but defensive against future additions) unambiguous.
        import SpeziScheduler
        import UserNotifications
    #endif

    /// Spezi `Standard` actor for HealthLog.
    ///
    /// SpeziHealthKit 1.4.x delivers sample changes through the collection-
    /// based `HealthKitConstraint` requirements (`handleNewSamples` /
    /// `handleDeletedObjects`). v0.5.5 (W-A3) wires the Standard up for the
    /// first cluster — Steps + ActiveEnergy — by routing observed samples
    /// through the same `MeasurementBatchUploader` + `uploadAndDecide`
    /// surface the legacy `HealthKitService` uses, so the upload behaviour,
    /// idempotency-key handling, anchor-after-200 policy, and BF-5
    /// diagnostics all stay bit-for-bit identical to the legacy per-sample
    /// path.
    ///
    /// **Coexist mode (v0.5.5 - v0.5.7):** the legacy `HealthKitService`
    /// stays authoritative for every other read type. A `useSpezi` feature
    /// flag on the legacy service filters Steps + ActiveEnergy out of its
    /// `defaultBackgroundDeliveryTypes` so we don't double-process the
    /// same samples. Until `attachUploader(_:featureFlags:)` is called by
    /// the composition root, observations land in the log + diagnostics
    /// counter only — anchors are advanced (`.consumed` semantics).
    ///
    /// **Why the standard owns the uploader instead of pulling it from
    /// the Spezi module graph?** `MeasurementBatchUploader` is not a Spezi
    /// `Module` — it's a plain actor that pre-dates Spezi adoption and
    /// stays the integration seam for the entire HealthKit write path
    /// (BF-5 + the legacy observer pipeline + Spezi). Modeling it as a
    /// Spezi Module would require a server-side composition root rebuild;
    /// the simpler setter-injection mirrors the existing
    /// `HealthKitService.attachUploader` shape.
    actor HealthLogStandard: Standard, HealthKitConstraint {
        /// Composition-root-injected batch uploader. nil until
        /// ``attachUploader(_:featureFlags:)`` runs (`AppContainer.init`
        /// in the production path).
        private var uploader: MeasurementBatchUploader?
        private var uploaderWaiters: [CheckedContinuation<MeasurementBatchUploader, Never>] = []

        /// Composition-root-injected feature-flag reader. nil until
        /// ``attachUploader(_:featureFlags:)`` runs. The Standard needs it
        /// to mirror the HK-STATS gate (v1.4.30 R-A Option A) the legacy
        /// `HealthKitService` already applies: when `enableDailyStats` is
        /// ON, the five cumulative HK identifiers (Steps + ActiveEnergy
        /// included) flow through `HealthKitStatisticsSyncCoordinator`
        /// with `externalId="stats:<id>:<YYYY-MM-DD>"`, so the per-sample
        /// batch path must NOT upload them. Anchors still advance.
        private var featureFlags: (any FeatureFlagsServicing)?

        /// Per-sample HR-bucket gate (W-HR-BUCKET-UPLOAD / GH #34).
        /// Maps a sample's date → "does this date upload as 10-minute buckets"
        /// — when `true` (and the HR-bucket flag is ON) the heartRate sample is
        /// dropped from the per-sample batch (the bucket sweep owns it). nil
        /// until ``attachUploader`` runs; when nil the gate is a no-op (no HR
        /// drop), so a pre-composition observation never loses data.
        ///
        /// Injected as a closure rather than a userID provider so the gate is
        /// hermetically testable: the production default reads
        /// ``HRUploadModeSchedule`` (the armed ``HRBucketCutoverStore`` boundary
        /// plus every operator raw/bucket switch on top of it, all stepping on
        /// UTC midnights so the answer is constant across a day) against the
        /// live user-id; tests pass a fixed predicate without touching
        /// `UserDefaults.standard`.
        private var hrCutoverGate: (@Sendable (Date) -> Bool)?

        /// Composition-root-injected durable-retry queue (Phase 07 Wave 2). nil
        /// until ``attachUploader`` runs and in unit tests that do not exercise
        /// the retry path.
        ///
        /// **What replaced the held floor.** Until Phase 07 this slot held a
        /// handle on SpeziHealthKit's per-type `queryAnchors` LocalStorage, and a
        /// held upload recorded a "resume floor" that the next wake wrote back.
        /// That mechanism could not work: the collector persists the query anchor
        /// unconditionally after this handler returns, and the page it produced
        /// was already consumed by the query that ran *before* the handler — a
        /// rewind cannot recover it (`HealthKitDurableCursorTests`
        /// `/callbackRewindIsOverwritten` models the exact upstream order). The
        /// durable form of "this page was not accepted" is an owner-bound outbox
        /// row, which survives a restart and carries its own derived idempotency
        /// key, so that is what this slot now holds.
        private var retryQueue: (any HealthSyncBatchRetryEnqueuing)?

        /// Composition-root-injected server-deletion reconciler (A360-5 M-1).
        /// nil until ``attachDeletionReconciler(_:)`` runs (and in unit tests
        /// that don't exercise the delete path). When wired, a HealthKit
        /// deletion the user makes in Apple Health is mirrored to a server
        /// delete-by-external-id so the HK→server triangle is closed for
        /// deletes too (it was previously one-way → orphaned server rows).
        /// `internal` (not `private`) so the `+Deletions` extension file owns
        /// the `handleDeletedObjects` witness + setter (file_length split).
        var deletionReconciler: (any MeasurementDeletionReconciler)?

        /// Setter-injection from the composition root. Idempotent — re-
        /// calling with the same uploader is safe; the standard simply
        /// keeps the latest reference. Tests can detach by passing nil.
        ///
        /// `userIDProvider` defaults to nil so existing test call-sites compile
        /// unchanged; the HR-bucket gate then partitions on `_anonymous`.
        /// `hrCutoverGate` defaults to nil so the production call-site can pass
        /// just a `userIDProvider` and let the standard build the real gate;
        /// tests pass an explicit gate to pin a deterministic boundary.
        /// `retryQueue` defaults to nil so existing call-sites compile
        /// unchanged; production passes the live outbox so a page the server did
        /// not terminally accept becomes a durable row instead of a stalled
        /// anchor.
        func attachUploader(
            _ uploader: MeasurementBatchUploader?,
            featureFlags: (any FeatureFlagsServicing)?,
            userIDProvider: (@Sendable () -> String?)? = nil,
            hrCutoverGate: (@Sendable (Date) -> Bool)? = nil,
            retryQueue: (any HealthSyncBatchRetryEnqueuing)? = nil
        ) {
            self.uploader = uploader
            self.featureFlags = featureFlags
            self.retryQueue = retryQueue
            if let uploader {
                let waiters = uploaderWaiters
                uploaderWaiters.removeAll()
                waiters.forEach { $0.resume(returning: uploader) }
            }
            if let hrCutoverGate {
                self.hrCutoverGate = hrCutoverGate
            } else if let userIDProvider {
                // Production default — the live per-User upload-mode schedule.
                // `.buckets` ⇒ the bucket sweep owns this sample; `.raw` ⇒ it
                // stays on the per-sample path.
                self.hrCutoverGate = { date in
                    HRUploadModeSchedule.mode(at: date, userId: userIDProvider()) == .buckets
                }
            } else {
                self.hrCutoverGate = nil
            }
        }

        /// Notifies the standard about a batch of newly observed HealthKit
        /// samples for `sampleType`.
        ///
        /// The mapping half is unchanged and now lives in one place
        /// (``HealthSampleWireGate``) so the app-owned collector and this Spezi
        /// witness cannot drift:
        ///
        /// 1. Anti-echo filter (samples this app wrote, carrying our external
        ///    UUID *and* authored by our own HK source).
        /// 2. Wire conversion to `HealthKitBatchEntryDTO`.
        /// 3. The HK-STATS and HR-bucket gates.
        ///
        /// What changed in Phase 07 is the fourth step. The handler no longer
        /// tries to move a cursor: SpeziHealthKit persists the query anchor
        /// unconditionally once this method returns, so nothing written here can
        /// hold it. Instead the page is classified into a
        /// ``HealthSyncPageOutcome`` and handed to the installed commit rule
        /// (``HealthSyncCursorPolicy``), which is the same rule the app-owned
        /// collector commits under. The verdict drives the honest
        /// `anchorAdvanced` diagnostic; the durable recovery for a page the
        /// server did not accept is the owner-bound outbox row the shared
        /// consumption operation writes.
        ///
        /// The `Sample` generic is bound by `SampleType<Sample>`'s own
        /// requirement (`_HKSampleWithSampleType`); every concrete
        /// resolution is therefore an `HKSample` subclass, which makes the
        /// `as HKSample` upcast sound rather than force-cast territory.
        func handleNewSamples<Sample>(
            _ addedSamples: some Collection<Sample> & Sendable,
            ofType sampleType: SampleType<Sample>
        ) async {
            guard !addedSamples.isEmpty else { return }
            // The Spezi witness owns no cursor partition, so it makes no
            // admission: there is no owner it could attribute a durable retry to.
            _ = await consumePage(
                addedSamples.map { $0 as HKSample },
                ofType: sampleType.hkSampleType.identifier,
                admitted: nil
            )
        }

        /// Maps, transmits, classifies, and reports one page.
        ///
        /// Shared by the Spezi witness above and — through
        /// ``HealthSamplePageConsuming`` — by ``AnchoredHealthSampleCollector``,
        /// which supplies the admission and then decides the cursor itself.
        func consumePage(
            _ samples: [HKSample],
            ofType typeID: String,
            admitted lease: HealthSyncAuthenticatedLease?
        ) async -> HealthSyncPageOutcome {
            let gate = wireGate
            let mapping = gate.map(samples)

            guard !mapping.entries.isEmpty else {
                // Distinguish "dropped SOLELY by a gate" from "genuinely nothing
                // to upload". When rows existed before the gates and none
                // survived, the real upload happens authoritatively over the
                // daily-statistics or HR-bucket path; recording zero uploaded
                // here would make every cumulative kind look permanently stuck in
                // the diagnostics surface. Nothing is posted, so no uploader is
                // resolved and an early observation is not made to wait for one.
                HLLog.healthKit
                    .info(
                        "Spezi HK \(typeID, privacy: .public) — \(mapping.readCount, privacy: .public) foreign samples, 0 entries after gate"
                    )
                await recordObservation(
                    identifier: typeID,
                    samplesRead: mapping.readCount,
                    samplesUploaded: mapping.handedToAggregatePath ? mapping.readCount : 0,
                    anchorAdvanced: true
                )
                return HealthSyncPageOutcome(
                    postedCount: 0,
                    entries: [],
                    transportThrew: false,
                    durableRetryPersisted: false,
                    durableRetryFailed: false,
                    leaseIsCurrent: true,
                    wasCancelled: false
                )
            }

            let consumption = await HealthSampleConsumption(
                uploader: resolvedUploader(logging: typeID),
                gate: gate,
                retry: retryQueue
            )

            // CU-21 (1) — a delivery that arrives WHILE the app is backgrounded IS
            // a background sweep: iOS woke the process for it. The state is read
            // before the upload so the wire field is set in time. In the
            // foreground no window is opened, so an enclosing BGTask window is not
            // overwritten.
            let outcome: HealthSyncPageOutcome = if await Self.isApplicationBackgrounded() {
                await SyncTriggerContext.shared.withTrigger(.background) {
                    await consumption.transmit(mapping, admitted: lease)
                }
            } else {
                await consumption.transmit(mapping, admitted: lease)
            }

            // The single decision point. `installed` is the rule production runs;
            // it is compared against `required` by the Wave-0 matrix.
            let advanced = HealthSyncCursorPolicy.installed.decide(outcome) == .commit
            await recordObservation(
                identifier: typeID,
                samplesRead: mapping.readCount,
                samplesUploaded: advanced ? mapping.entries.count : 0,
                anchorAdvanced: advanced
            )
            return outcome
        }

        /// The mapping/gate configuration this standard currently runs.
        ///
        /// AUD-3 D-1 — the daily-statistics gate FAILS CLOSED in the unconfigured
        /// window. A raw per-sample row (uuid external id) and a `stats:` row
        /// carry different external ids the server cannot collapse, so a day that
        /// gets both double-counts in the nightly rollup. `enableDailyStats`
        /// defaults ON and the stats coordinator is authoritative for the
        /// cumulative types, so the safe default while the flag reader is not yet
        /// attached is to treat the gate as ENABLED.
        private var wireGate: HealthSampleWireGate {
            HealthSampleWireGate(
                dailyStatsEnabled: featureFlags?.isEnabled(.enableDailyStats) ?? true,
                hrBucketGate: (featureFlags?.isEnabled(.enableHRBuckets) ?? false) ? hrCutoverGate : nil
            )
        }

        /// The attached uploader, waiting for composition when an observation
        /// arrives before `attachUploader` has run. Unchanged from the
        /// pre-Phase-07 path: an early observation is retained, never dropped.
        private func resolvedUploader(logging typeID: String) async -> MeasurementBatchUploader {
            if let uploader { return uploader }
            HLLog.healthKit
                .debug(
                    "Spezi HK \(typeID, privacy: .public) observed before uploader attached — page retained"
                )
            return await withCheckedContinuation { continuation in
                uploaderWaiters.append(continuation)
            }
        }

        /// **CU-21 (1)** — is the app currently backgrounded? `UIApplication` is
        /// `@MainActor`-isolated, so the actor-isolated `handleNewSamples` has
        /// to hop for the read. Non-UIKit builds answer `false` (no background
        /// runtime to speak of).
        private static func isApplicationBackgrounded() async -> Bool {
            #if canImport(UIKit)
                await MainActor.run { UIApplication.shared.applicationState == .background }
            #else
                false
            #endif
        }

        /// Hop to MainActor to bump the BF-5 diagnostics counter.
        /// `HKSyncDiagnostics.shared.recordObservation` is `@MainActor`
        /// because it backs a SwiftUI surface; the actor-isolated
        /// `handleNewSamples` cannot reach it directly.
        private func recordObservation(
            identifier: String,
            samplesRead: Int,
            samplesUploaded: Int,
            anchorAdvanced: Bool
        ) async {
            await MainActor.run {
                HKSyncDiagnostics.shared.recordObservation(
                    identifier: identifier,
                    samplesRead: samplesRead,
                    samplesUploaded: samplesUploaded,
                    anchorAdvanced: anchorAdvanced
                )
                // #66 P0.1 (Baustein 4) — a delivery while backgrounded is the
                // vital-sign background path; record it as honest evidence.
                #if canImport(UIKit)
                    if UIApplication.shared.applicationState == .background {
                        HKSyncDiagnostics.shared.recordWake(.observer)
                    }
                #endif
            }
        }
    }

    // MARK: - App-owned collection

    /// The mapping/transmission seam ``AnchoredHealthSampleCollector`` calls.
    ///
    /// The collector owns *when* a page is read and whether its cursor moves; the
    /// standard owns the anti-echo filter, the wire conversion, and the two upload
    /// gates. Sharing this one implementation is what keeps the app-owned path and
    /// the Spezi witness from drifting into two different definitions of "what we
    /// send".
    extension HealthLogStandard: HealthSamplePageConsuming {
        func consume(
            _ samples: [HKSample],
            ofType typeIdentifier: String,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            await consumePage(samples, ofType: typeIdentifier, admitted: lease)
        }
    }

    // MARK: - SpeziScheduler integration (Phase E)

    #if canImport(SpeziScheduler) && canImport(UserNotifications)
        /// `SchedulerNotificationsConstraint` lets the app's `Standard`
        /// intercept + rewrite the `UNMutableNotificationContent` Spezi-
        /// Scheduler builds before it lands on the user-notification
        /// center. We use it as the single seam that preserves the
        /// existing 3-action medication category contract:
        ///
        /// 1. `categoryIdentifier` is rewritten from Spezi's derived
        ///    `edu.stanford.spezi.scheduler.notification.category.<raw>`
        ///    back to our `MEDICATION_REMINDER` — that's the id the
        ///    existing `UNNotificationCategory` registers its 3 actions
        ///    (Genommen / Snooze 15 Min / Übersprungen) under, so the
        ///    banner renders the chrome the operator validated on
        ///    TestFlight.
        /// 2. `userInfo` is shaped to match `NotificationService.medication-
        ///    UserInfo(...)` — `medicationId` + `scheduleId` + `scheduled-
        ///    For` + `eventType`. That is exactly what `dispatchAction`
        ///    parses via `APNsPayload.parse(userInfo:)` to drive the
        ///    server `recordFromReminder(...)` round-trip on "Genommen"
        ///    or "Übersprungen". Without this rewrite the action handler
        ///    would fall through to the deep-link path and the server
        ///    mark-intake would never fire.
        ///
        /// The `borrowing` parameters compile-check cleanly here because
        /// `UNMutableNotificationContent` is a `class` — its mutators
        /// don't require `inout`, and `borrowing` only forbids re-binding
        /// the parameter, not calling reference-type setters on it.
        extension HealthLogStandard: SchedulerNotificationsConstraint {
            // Witness for `SchedulerNotificationsConstraint.notification-
            // Content(for:content:)`. The protocol declares the method
            // `@MainActor`; we honour that here without an explicit
            // `nonisolated` because `HealthLogStandard` itself is an
            // `actor` and the constraint hook needs to hop to the main
            // actor anyway (`UNMutableNotificationContent.userInfo` is
            // not marked Sendable and Spezi expects to read the rewrite
            // before the request lands on `UNUserNotificationCenter`).
            @MainActor
            func notificationContent(
                for task: borrowing SpeziScheduler.Task,
                content: borrowing UNMutableNotificationContent
            ) {
                // Only medication tasks get the rewrite — leave any
                // future Spezi-scheduled categories (questionnaires,
                // measurements) on the upstream defaults.
                guard task.category == .medication else { return }

                // The actual rewrite lives in the pure static helper so
                // tests can exercise it without booting a real
                // `SpeziScheduler.Task` (which would require a full Spezi
                // module graph). Only the inputs the helper needs —
                // the Spezi-derived task id and the mutable content —
                // cross the boundary here.
                Self.rewriteMedicationNotificationContent(
                    taskID: task.id,
                    content: content
                )
            }

            /// Pure rewrite applied to a Spezi-derived medication banner.
            ///
            /// Splitting this out of the protocol witness above gives us
            /// a hermetically testable surface that pins the four
            /// invariants the operator-validated TestFlight banner
            /// relies on:
            ///
            /// 1. `interruptionLevel == .timeSensitive` so the banner
            ///    breaks through Focus / Do Not Disturb. Pairs with the
            ///    `com.apple.developer.usernotifications.time-sensitive`
            ///    entitlement (set in `HealthLog.entitlements`); without
            ///    both the system silently demotes back to `.active`.
            ///    Medication adherence is the canonical Apple use-case
            ///    for time-sensitive — questionnaires + achievement
            ///    banners intentionally stay on `.active` by virtue of
            ///    the `task.category == .medication` guard in the
            ///    witness above.
            /// 2. `badge` nil-ed out so the centrally-driven
            ///    `MedicationsStore.dueOrMissedCount` stays the single
            ///    source of truth (v0.6.1.3 Y4.1).
            /// 3. `categoryIdentifier == "MEDICATION_REMINDER"` so iOS
            ///    renders the 3-action chrome the operator validated.
            /// 4. `userInfo` shaped to
            ///    `NotificationService.medicationUserInfo(...)` so the
            ///    action handler can POST the server mark-intake on
            ///    "Genommen" / "Übersprungen".
            ///
            /// `@MainActor` because `UNMutableNotificationContent`'s
            /// mutators are not Sendable and Spezi expects the rewrite
            /// on the main actor (mirrors the witness contract).
            @MainActor
            static func rewriteMedicationNotificationContent(
                taskID: String,
                content: UNMutableNotificationContent
            ) {
                // W-B188 (AUDIT-SEC-b187 High) — when the user opted in to
                // "hide medication name on lock screen", redact the visible
                // text: the title (set by `MedicationsSchedulerModule.
                // localizedTitle` to the raw drug NAME) becomes a generic
                // localized label and the body (the DOSE) is dropped. The
                // `userInfo` rewrite below still carries `medicationId`, so
                // the 3-action chrome (Taken / Snooze / Skipped) keeps working
                // — only the human-readable PHI on the lock screen is hidden.
                // Default OFF → no behaviour change unless the user opts in.
                if LockScreenPrivacy.hideMedicationName() {
                    content.title = String(localized: "Medication reminder")
                    content.body = ""
                }

                // Promote the banner to time-sensitive so it breaks
                // through Focus / Do Not Disturb. Without this — and
                // without the matching entitlement — the system silently
                // demotes back to `.active` and the user never sees the
                // banner mid-Focus.
                content.interruptionLevel = .timeSensitive

                // v0.6.1.3 Y4.1 — the App-Badge is driven centrally
                // from `MedicationsStore.dueOrMissedCount`. Explicitly
                // nil-out any Spezi-derived `badge` so a delivered
                // banner does not bump the badge in parallel — the next
                // `refreshBadge(from:)` call will publish the
                // authoritative number.
                content.badge = nil

                // Read the task-context user-info we wrote at
                // `createOrUpdateTask` time. The Spezi `@dynamicMember-
                // Lookup` on `Task.Context` is via the
                // `@Property(coding:)` macro; we keep the metadata in a
                // plain dictionary on the task's `userInfo` field via
                // `MedicationsSchedulerModule.taskUserInfo(...)`.
                let medicationId = MedicationsSchedulerModule
                    .medicationId(fromTaskID: taskID)
                let scheduleId = MedicationsSchedulerModule
                    .scheduleId(fromTaskID: taskID)

                // Rewrite the category id so the banner picks up the
                // existing `MEDICATION_REMINDER` action set. The
                // upstream Spezi-derived id is shadowed.
                content.categoryIdentifier = NotificationService.categoryMedication

                // Shape the userInfo dict to the canonical
                // `medicationUserInfo(...)` contract. The `scheduledFor`
                // we attach here is only a placeholder: this hook runs when
                // Spezi BUILDS the request (every reconcile), sees task +
                // content but never the trigger, and the occurrence start
                // lives only in the request identifier. The action handler
                // therefore ignores this value for `speziScheduled` banners
                // and resolves `scheduledFor` from the delivery date
                // (`NotificationService.resolvedPayload(userInfo:deliveredAt:)`)
                // — Spezi fires at the occurrence start, so the delivery
                // instant is the slot.
                let scheduledFor = Date()
                if let medicationId {
                    var userInfo = NotificationService.medicationUserInfo(
                        medicationId: medicationId,
                        scheduleId: scheduleId,
                        scheduledFor: scheduledFor
                    )
                    // Mark this banner as Spezi-driven so logs +
                    // observability can tell it apart from a server APNs
                    // push. Mirrors the `localBackup: true` marker the
                    // legacy `scheduleLocalBackups` builder used.
                    userInfo["speziScheduled"] = true
                    content.userInfo = userInfo
                }
            }
        }
    #endif
#endif
