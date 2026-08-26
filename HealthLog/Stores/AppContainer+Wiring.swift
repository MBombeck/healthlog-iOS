import Foundation

// MARK: - Runtime-hook wiring (extracted from `AppContainer.init`)

extension AppContainer {
    // 09-08 — composition-root wiring, and the one place the relative order of
    // the hooks is visible. This body is already the *result* of an extraction
    // (it was inline in the designated init); splitting it again would scatter
    // an ordering contract that a reader currently checks by scrolling once.
    // function_body_length exception (owner: 09-08): ordered composition-root hook installation.
    // swiftlint:disable function_body_length
    /// Installs every cross-store runtime hook whose only inputs are
    /// already-built stored properties of the container. These closures /
    /// bindings are pure side effects: each writes a callback slot or binds an
    /// observable that fires LATER (never during init), so running them all at
    /// the end of the designated init — in the same relative order they used to
    /// sit inline — is behaviour-identical. Lifting them here keeps the init
    /// body inside its lint budget without moving any stored-property
    /// construction (which must stay in the designated init).
    ///
    /// Called from `init` AFTER all stores exist and BEFORE `wireLogoutHooks`
    /// (the logout cascade hooks must stay last — they weakly capture a fully
    /// initialised `self`).
    func configureRuntimeWiring(apiClient: APIClient, bgSync: BackgroundSyncCoordinator) {
        // HK-Anchor-Cleanup-Hook für Logout (incl. 401-Bridge). 401 wipes the
        // token from Keychain via `AuthStore.handleUnauthorized` — we must wipe
        // the per-user HK anchors there too, else the next user's samples land
        // on the old anchor cursor.
        authStore.setOnLogoutCleanup { previousUserID in
            #if canImport(HealthKit)
                HealthKitService.clearAnchors(for: previousUserID)
            #endif
            HealthKitBackfillWindowStore.clear(for: previousUserID)
            // W-HR-BUCKET-UPLOAD / GH #34 — re-arm HR-bucket cutover on re-login,
            // and drop the operator's raw/bucket schedule with it: it describes
            // one account's server rows, so the next account starts from the
            // shipping default instead of inheriting a choice nobody made there.
            HRBucketCutoverStore.clear(for: previousUserID)
            HRUploadModeSchedule.clear(for: previousUserID)
            // GH #86 — the workout-HR backfill cursor is user-bound too; the
            // next account starts its own walk over its own history.
            WorkoutHRBackfillStore.clear(for: previousUserID)
        }

        #if canImport(UserNotifications) && canImport(UIKit)
            // v0.6.1.3 Y4.1 + Y8 — badge-recompute path + foreground-banner
            // store accessor (single-slot coalescer; `[weak]` captures).
            Self.wireBadgeRefresh(
                notifications: notifications,
                medicationsStore: medicationsStore,
                coalescer: badgeRefreshCoalescer
            )
            // v0.14.1 notifications-bug H2 — feed the "already logged today?"
            // signal to the foreground `willPresent` delegate so the now-repeating
            // mood reminder can suppress its banner when a mood entry already
            // exists for today (the scheduling step no longer gates on it).
            notifications.moodLoggedTodayAccessor = { [weak moodStore] in
                moodStore?.todayEntry() != nil
            }
        #endif

        // v0.9.0 W2 — feed the per-med critical-alarm opt-in predicate provider
        // into the medications store so its Spezi-reconcile pass can route
        // alarm-owned meds onto the AlarmKit channel (REPLACE) and exclude them
        // from the UNNotification set. A fresh @Sendable snapshot is produced on
        // the MainActor per reconcile (no assumeIsolated).
        medicationsStore.criticalAlarmEnabledProvider = { [weak deliveryPreferencesStore] in
            deliveryPreferencesStore?.enabledPredicate(for: .criticalAlarm) ?? { _ in false }
        }
        // v0.10 W-Meds-A2 (v1.7.0 SB-LA-1 / SB-AK-1) — fold the per-medication
        // `liveActivityEnabled` / `criticalAlarmEnabled` server booleans into the
        // delivery-prefs server-default cache on every medications load. Against
        // the current server (fields absent) this is a no-op per med.
        medicationsStore.onMedicationsDidChange = { [weak deliveryPreferencesStore] medications in
            deliveryPreferencesStore?.ingestServerDefaults(from: medications)
        }
        #if canImport(ActivityKit)
            // v0.8.4 WWIDGET-1 — hook the Live Activity controller onto the
            // intake-change path so the soonest due dose surfaces / updates /
            // clears as the user acts.
            Self.wireMedicationLiveActivity(
                controller: medicationLiveActivityController,
                medicationsStore: medicationsStore,
                deliveryPreferences: deliveryPreferencesStore
            )
            // v0.16.1 W-LA-BG (LIVE-ACTIVITY BACKGROUND START) — also reconcile
            // the Live Activity from the guaranteed-sync BGProcessingTask so a
            // dose that becomes due *while the app is backgrounded* STARTS its
            // Live Activity (not only the local notification). Awaited inline in
            // the BGTask window, after the med-store reconcile loads the day's
            // intakes. Fixes the "LA only appears after I open + re-background
            // the app" operator report.
            Self.wireLiveActivityBackgroundReconcile(
                backgroundSync: bgSync,
                controller: medicationLiveActivityController,
                medicationsStore: medicationsStore,
                deliveryPreferences: deliveryPreferencesStore
            )
        #endif
        // v0.8.4 WWIDGET-2 — refresh the App Group widget snapshot + reload the
        // Home / Lock-Screen widget timelines on every intake change.
        Self.wireWidgetSnapshot(
            writer: widgetSnapshotWriter,
            medicationsStore: medicationsStore
        )
        // 09-03 — the logout clear closes the widget writer's admission so a
        // callback belonging to the account being torn down cannot land after
        // the placeholder. The next admitted authenticated owner is what
        // re-opens it; the registry's admission signal is the one statement
        // every login path already reaches.
        authenticatedSessionRegistry.observeAdmissions { [widgetSnapshotWriter] _ in
            Task { @MainActor in widgetSnapshotWriter.admitNextAccount() }
        }
        // W-B187 QOL-2 — drive the CoreSpotlight index off the stores' settle
        // hooks (med NAMES + neutral measured-kind titles, NO PHI). The med hook
        // is the dedicated `onMedicationsListSettled` slot (NOT
        // `onMedicationsDidChange`, which the delivery-prefs wiring owns).
        medicationsStore.onMedicationsListSettled = { [weak spotlightCoordinator] medications in
            spotlightCoordinator?.reindexMedications(medications)
        }
        measurementsStore.onAvailabilityDidChange = { [weak spotlightCoordinator] kinds in
            spotlightCoordinator?.reindexMeasurements(kinds: Array(kinds))
        }
        // b181 W-B181 (DOUBLE-DOSE SAFETY) — drive a med-store revalidation from
        // the guaranteed-sync BGTask so a dose taken on the WEB / a second device
        // reconciles the Live Activity + widgets even without an app foreground.
        Self.wireMedicationReconcileHook(
            backgroundSync: bgSync,
            medicationsStore: medicationsStore
        )
        // Reliability M1 (audit-v0162) — drain the encrypted Outbox from the
        // guaranteed-sync BGTask so an offline-logged user write replays on a BG
        // wake instead of waiting for the next app foreground. Probe-gated on
        // `confirmedReachable()` inside the hook.
        wireOutboxBGDrainHook(backgroundSync: bgSync)
        // #66 P0.1 (Baustein 1) — arm the new BGAppRefreshTask's collection
        // trigger so the frequent AppRefresh wake pulls the ~28 manual-collector
        // HK types toward the server without waiting for a foreground.
        wireBGRefreshCollectionHook(backgroundSync: bgSync)
        // Direct HKWorkout collection is not part of Spezi's sample collector
        // DSL. Prepare it here from authenticated composition-root state so a
        // cold BG launch does not depend on RootView mounting first.
        Self.wireWorkoutBackgroundSync(
            backgroundSync: bgSync,
            healthKit: healthKit,
            repository: serverStatsRepos.workouts,
            store: serverStatsStores.workouts,
            authStore: authStore,
            keychain: keychain
        )
        // The Settings/Insights “sync now” affordance must reach every
        // HealthKit path that is already enabled, not only Spezi collectors.
        // The optional stores keep their explicit-consent gates: calling these
        // methods never flips a toggle or requests sensitive authorization.
        // **Phase 07 / plan 07-09** — one route, not a list. This used to
        // enumerate three calls (`runManualHealthSyncPass`, the Mood mirror, the
        // Apple-medication mirror), which is how "Jetzt syncen" came to mean a
        // different set of importers than a foreground tick or a background wake
        // — and how it came to run all of them twice once the orchestrated pass
        // existed. The readiness store now names its trigger and the orchestrator
        // resolves the plan.
        hkReadinessStore.attachHealthSyncRoute { [weak self] trigger in
            await self?.runHealthSyncPass(trigger)
        }
        // v0.10.0 W-Mood-B — refresh the mood widget glance on every entry change.
        Self.wireMoodWidgetSnapshot(
            writer: widgetSnapshotWriter,
            moodStore: moodStore
        )
        // v0.12 P2 — wire the watchOS companion onto the live stores: watch
        // intake/mood actions funnel into the canonical store methods; the phone
        // re-pushes a fresh snapshot on change.
        Self.wireWatchCompanion(
            coordinator: watchSession,
            medicationsStore: medicationsStore,
            moodStore: moodStore,
            measurementsStore: measurementsStore,
            keychain: keychain
        )
        // b177 W-SYNCPROGRESS — feed the sync-status footer's honest quantities:
        // live outbox backlog + in-flight SWR revalidation count.
        serverStatsStores.syncState.bindOutbox(outbox)
        serverStatsStores.syncState.bindRevalidations(swr)
        // v0.15 companion-#3 — drive the two glance widgets (Personal Health
        // Score ring + latest-measurement) from the App Group snapshot. Score
        // mirrors the server value verbatim; latest-measurement formats the
        // newest reading through the user's unit preferences.
        Self.wireHealthScoreWidgetSnapshot(
            writer: widgetSnapshotWriter,
            healthScoreStore: healthScoreStore
        )
        Self.wireLatestMeasurementWidgetSnapshot(
            writer: widgetSnapshotWriter,
            measurementsStore: measurementsStore,
            unitPreferences: { [settingsStore] in settingsStore.unitPreferences }
        )
        // v0.15.2 W-WATCH-COMPLICATIONS — feed the watch-face score-ring +
        // latest-measurement complications from the SAME score / measurement
        // sources the phone widgets use (read lazily on every push).
        Self.wireWatchGlances(
            coordinator: watchSession,
            healthScoreStore: healthScoreStore,
            measurementsStore: measurementsStore,
            unitPreferences: { [settingsStore] in settingsStore.unitPreferences }
        )
        #if canImport(UserNotifications) && canImport(UIKit)
            // W-THRESHOLD-NUDGE — MDR-safe out-of-range nudge onto the labs
            // store. Acts ONLY on the server's own range verdict, opt-in
            // (default off), defers to an active server illness escalation, and
            // debounces a standing breach.
            labsStore.thresholdNudge = ThresholdNudgeCoordinator.live(
                notifications: notifications,
                illnessStore: illnessStore
            )
            // v1.18.6 (#32) — Vorsorge reminder server-completion seam so the
            // foreground "Erledigt" notification action POSTs `…/{id}/complete`
            // (server-authoritative) instead of only dismissing the banner.
            notifications.measurementReminderCompleter = { [weak measurementRemindersStore] id in
                guard let measurementRemindersStore else { return false }
                return await measurementRemindersStore.complete(id: id)
            }
            // LOGOUT-NOTIF — default the logout notification-clear seam to the
            // real NotificationService purge (delivered + pending + badge).
            notificationClearOnLogoutHook = { [weak notifications] in
                await notifications?.clearAllNotificationsOnLogout()
            }
        #endif
        // v0.14 DATA + v0.14.8 dashboard-summary day-anchor
        Self.wireMedicationDueTimeZone(
            medicationsStore: medicationsStore,
            dashboardStore: dashboardStore,
            dailyBriefingStore: dailyBriefingStore,
            settingsStore: settingsStore,
            measurementsRepo: measurementsRepo,
            profileTimeZoneBox: profileTimeZoneBox
        )
        // audit-v0162 M-7 — WIRE the derived-intake synthesis gate. It shipped
        // as `= { true }` with a "until wired" note and was never connected, so
        // the client synthesised placeholders on EVERY server — including the
        // slot-materialising ones, where a >5-min `scheduledFor` divergence
        // parks the placeholder next to the real row (inflated "N offen",
        // phantom overdue ring dose, inflated badge). Read live off the gate so
        // the first `/api/version` probe of the session flips it without
        // re-building the store; the gate persists its last-known verdict, so
        // the pre-probe window is a once-per-installation event, not a
        // once-per-cold-launch one.
        //
        // Standalone mode is OR'd back in: there is no server there at all, so
        // the local mirror only ever holds doses the operator already logged
        // and the synthesis is the ONLY source of "due today". Suppressing it
        // in standalone would empty the due surfaces outright. Captured as a
        // value (the store already owns this closure) so no cycle is created.
        let medicationsAreStandalone = medicationsStore.isStandalone
        medicationsStore.derivedIntakeSynthesisEnabledProvider = { [weak medicationSlotGate] in
            if medicationsAreStandalone() { return true }
            return medicationSlotGate?.synthesisEnabled ?? false
        }
        // v0.10.0 W-Mood-B — reconcile the iOS-local evening mood reminder
        // whenever the mood entries change in-session (log / edit / delete): a
        // fresh today-entry cancels the pending reminder so it never
        // double-fires with the server APNs push.
        Self.wireMoodReminderReconcile(
            moodStore: moodStore,
            notifications: notifications,
            settingsStore: settingsStore
        )
        // v0.15.5 AUD-1 F4 — also re-arm the local evening mood reminder from the
        // guaranteed-sync BGProcessingTask wakeup, so the non-repeating
        // `mood-reminder-local` trigger keeps firing on days the app is never
        // opened.
        Self.wireMoodReminderBackgroundRearm(
            backgroundSync: bgSync,
            moodStore: moodStore,
            notifications: notifications,
            settingsStore: settingsStore
        )
        // v0.5.5 W-A3 — hand the live flags to the legacy HKService + wire the
        // Spezi-side uploader.
        Self.attachLiveFlagsAndSpeziUploader(
            healthKit: healthKit,
            uploader: healthKitUploader,
            featureFlagsStore: featureFlagsStore,
            keychain: keychain,
            // A360-5 M-1 — the repo conforms to `MeasurementDeletionReconciler`;
            // thread it so Apple-Health deletions propagate to the server
            // delete-by-external-id endpoint.
            deletionReconciler: measurementsRepo,
            // Phase 07 Wave 2 — a page the server did not terminally accept
            // becomes a durable owner-bound row rather than a stalled anchor,
            // and the app-owned collector admits through the Phase-06 registry.
            retryQueue: outbox,
            authenticatedSessionRegistry: authenticatedSessionRegistry
        )
        Self.wireAssistantDisabledMirror(apiClient: apiClient, store: featureFlagsStore)
        Self.wireModuleDisabledMirror(apiClient: apiClient, gate: moduleGate) // #30
    }

    // swiftlint:enable function_body_length

    /// **Phase 09 / plan 09-02 — the launch sweep for owned import residue.**
    ///
    /// The Apple-Health import assembles its multipart body into an app-owned,
    /// complete-protected temp file and deletes it on every exit it controls. A
    /// crash, a jetsam kill or a power loss mid-upload is not an exit it
    /// controls, and what survives is the user's whole health archive sitting in
    /// the temp directory.
    ///
    /// This runs at launch, from the launch task itself, for two reasons that
    /// are both about *when* rather than *what*:
    ///
    /// * **Not a lazy service initializer.** `makeExportStore()` builds the
    ///   import surface on demand, so a sweep hung off it would run only for
    ///   users who opened the import screen again — that is, everybody except
    ///   the person whose import just crashed.
    /// * **Not a fire-and-forget sibling.** A detached task can outlive or be
    ///   dropped by the launch it belongs to, and nothing would notice. The
    ///   call site awaits this as a structured child.
    ///
    /// `nonisolated static` so the sweep is reachable from the launch task
    /// without a composition root, and so the test drives the exact function
    /// the app does rather than a copy of it.
    nonisolated static func sweepAppleHealthImportTemps(
        store: AppleHealthImportTempStore = .live,
        now: Date = .now,
        ttl: TimeInterval = AppleHealthImportTempStore.defaultTTL
    ) async -> [URL] {
        await store.sweepStale(now: now, ttl: ttl)
    }

    /// Starts the outbox-replay loop: arms a replay on each online interface
    /// edge (+ the initial auth-bootstrap edge). QoL-3-H-3 — the edge only
    /// *arms*; we confirm the server actually answers (`/api/health`) before
    /// draining, so a captive-portal Wi-Fi edge (NWPath satisfied but writes
    /// hang) is skipped and the next edge re-arms. The same owned task first
    /// attaches the honest DLQ sink, establishing a happens-before edge for the
    /// immediate-online replay. Returns the detached task so `deinit` can cancel
    /// it.
    func startOutboxReplayLoop() -> Task<Void, Never> {
        let reach = reachability
        let replay = outboxReplay
        let syncState = serverStatsStores.syncState
        return Self.startOutboxReplayBootstrap(
            reachability: reach,
            replay: replay,
            outbox: outbox,
            firstFrame: .shared,
            onDeadLettered: { count in
                await syncState.noteDeadLettered(count)
            },
            ownerIsAlive: { [weak self] in self != nil }
        )
    }

    /// Bounded bootstrap seam used by the composition root and its startup-order
    /// regression. Sink attachment and stream consumption intentionally share
    /// one task; adding an independent fire-and-forget attachment would reopen
    /// the immediate-online race.
    ///
    /// **Phase 09 / plan 09-05 — the ordinary foreground open lives here.**
    /// Three things happen in one owned task, in one order, and the order is the
    /// contract:
    ///
    ///  1. **The dead-letter sink is attached first**, before anything can start
    ///     a replay pass through this task. It is deliberately not gated on the
    ///     frame: a publication that arrives before a sink is now buffered by
    ///     `OutboxReplayService` rather than lost, and the earlier the sink is
    ///     in place, the less there is to buffer.
    ///  2. **Then the first frame is awaited**, which is the point of the plan.
    ///     Nothing here infers the frame from a `Task.yield`, a delay, or the
    ///     return of `AppContainer.init` — `FirstFrameSignal` is resumed from
    ///     the app root's real render callback and from nowhere else.
    ///  3. **Then the store is warmed and the interface edges are consumed.**
    ///     The warm-up is explicit rather than a side effect of the first
    ///     `runOnce`, so "the open happened after the frame" is one countable
    ///     event instead of a consequence of a network probe's timing.
    ///
    /// A launch that never draws — a `BGProcessingTask` wake — simply never gets
    /// past step 2 in *this* task, which is correct: the background drain hook
    /// and the foreground re-drain reach `runOnce` directly, and any real write
    /// opens the store on demand through the same shared handle.
    nonisolated static func startOutboxReplayBootstrap(
        reachability: any ReachabilityProviding,
        replay: OutboxReplayService,
        outbox: OutboxQueue,
        firstFrame: FirstFrameSignal,
        onDeadLettered: @escaping @Sendable (Int) async -> Void,
        ownerIsAlive: @escaping @Sendable () -> Bool
    ) -> Task<Void, Never> {
        Task.detached {
            await replay.attachDeadLetterSink(onDeadLettered)
            guard !Task.isCancelled, ownerIsAlive() else { return }

            await firstFrame.wait()
            guard !Task.isCancelled, ownerIsAlive() else { return }
            await outbox.prepareStore()
            guard !Task.isCancelled, ownerIsAlive() else { return }

            for await online in await reachability.isOnlineStream {
                guard !Task.isCancelled, ownerIsAlive() else { return }
                guard online else { continue }

                if await reachability.confirmedReachable() {
                    await replay.runOnce()
                }
                guard !Task.isCancelled, ownerIsAlive() else { return }
            }
        }
    }
}
