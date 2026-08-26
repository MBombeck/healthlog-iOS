#if canImport(ActivityKit)
    import ActivityKit
    import Foundation

    extension AppContainer {
        /// **v0.8.4 WWIDGET-1 — drive the medication Live Activity from the
        /// store.**
        ///
        /// Chains onto `MedicationsStore.onIntakesDidChange` (without
        /// clobbering the existing badge-refresh closure) so every time the
        /// medications / today's intakes change, we re-evaluate which dose —
        /// if any — should own the Live Activity, and start / update / end
        /// it accordingly. The actual decision is the pure
        /// ``MedicationLiveActivityPlan`` so it stays unit-testable; this
        /// method is the thin imperative glue + the push-to-start token
        /// subscription kick-off.
        ///
        /// **Idempotent:** the controller's `start` updates an existing
        /// Activity in place rather than stacking duplicates, so calling
        /// `reconcile` after every store load is safe.
        static func wireMedicationLiveActivity(
            controller: MedicationLiveActivityController,
            medicationsStore: MedicationsStore,
            deliveryPreferences: DeliveryPreferencesStore
        ) {
            // Begin listening for push-to-start tokens immediately so the
            // server can later start Live Activities remotely. No-op until
            // the OS delivers a token; harmless when Activities are off.
            controller.observePushToStartToken()

            // Compose with any pre-existing closure (badge refresh) so both
            // fire — single-slot callback, so we capture + call through.
            let previousIntakes = medicationsStore.onIntakesDidChange
            medicationsStore.onIntakesDidChange = { [weak controller, weak medicationsStore, weak deliveryPreferences] in
                previousIntakes?()
                guard let controller, let medicationsStore, let deliveryPreferences else { return }
                Self.reconcileMedicationLiveActivity(
                    controller: controller,
                    medications: medicationsStore.medications,
                    intakes: medicationsStore.todayIntakes,
                    isLiveActivityEnabled: deliveryPreferences.enabledPredicate(for: .liveActivity)
                )
            }

            // v0.14.1 — also reconcile on medication mutations (not only intake
            // changes). Enabling a medication's per-med "Live-Aktivität" toggle
            // saves via `store.update(...)` → `onMedicationsDidChange`, which
            // previously did NOT touch the Live Activity, so the banner only
            // appeared on the next intake-stream emission. Compose onto that
            // slot too (preserving the pre-existing server-default ingest) so the
            // freshly-saved flag surfaces the dose immediately. Reads happen on
            // the MainActor (the closure is `@MainActor`); the predicate snapshot
            // is read after the ingest so it reflects the new flag.
            let previousMeds = medicationsStore.onMedicationsDidChange
            medicationsStore.onMedicationsDidChange = { [weak controller, weak medicationsStore, weak deliveryPreferences] medications in
                previousMeds?(medications)
                guard let controller, let medicationsStore, let deliveryPreferences else { return }
                Self.reconcileMedicationLiveActivity(
                    controller: controller,
                    medications: medicationsStore.medications,
                    intakes: medicationsStore.todayIntakes,
                    isLiveActivityEnabled: deliveryPreferences.enabledPredicate(for: .liveActivity)
                )
            }
        }

        /// Re-evaluate the Live Activity against the current medications +
        /// intakes. Surfaces the soonest due dose, marks a taken/skipped
        /// dose's Activity as resolved (ending it shortly), and clears the
        /// Activity when nothing qualifies.
        static func reconcileMedicationLiveActivity(
            controller: any MedicationLiveActivityReconciling,
            medications: [Medication],
            intakes: [MedicationIntake],
            now: Date = .now,
            isLiveActivityEnabled: (String) -> Bool = { _ in true }
        ) {
            guard controller.areActivitiesEnabled else { return }

            // The pure plan decides; the ActivityKit mutations are async, so
            // we hop onto a MainActor task to await them off the synchronous
            // store callback. The per-medication toggle gates which dose may
            // surface (default OFF, opt-in per med — v0.8.5 WFIX-LA). The
            // `isLiveActivityEnabled` predicate is non-escaping, so the decision
            // is computed synchronously here and only the resolved (Sendable)
            // `dose` crosses into the Task — the awaited variant below re-runs
            // the same pure plan for the background path where it can await
            // inline.
            let dose = MedicationLiveActivityPlan.doseToSurface(
                medications: medications,
                intakes: intakes,
                now: now,
                isLiveActivityEnabled: isLiveActivityEnabled
            )
            let resolved = dose.map {
                MedicationLiveActivityPlan.isResolved(
                    medicationId: $0.medicationId,
                    scheduledFor: $0.scheduledFireDate,
                    intakes: intakes
                )
            }

            _Concurrency.Task { @MainActor in
                await applyLiveActivityDecision(
                    controller: controller,
                    dose: dose,
                    isResolved: resolved ?? false,
                    now: now
                )
            }
        }

        /// Awaited variant of ``reconcileMedicationLiveActivity(controller:medications:intakes:now:isLiveActivityEnabled:)``.
        ///
        /// Performs the ActivityKit start / update / end mutations **inline**
        /// (no fire-and-forget `Task`) so the caller can `await` the whole
        /// reconcile. This is the path the background `BGProcessingTask` uses
        /// (v0.16.1 W-LA-BG): a dose that becomes due *while the app is
        /// backgrounded* must have its Live Activity `Activity.request`
        /// completed **before** the BGTask calls `setTaskCompleted` (which can
        /// suspend the process). The synchronous store-callback path keeps using
        /// the fire-and-forget wrapper above so it stays non-blocking.
        @MainActor
        static func reconcileMedicationLiveActivityAwaiting(
            controller: any MedicationLiveActivityReconciling,
            medications: [Medication],
            intakes: [MedicationIntake],
            now: Date = .now,
            isLiveActivityEnabled: (String) -> Bool = { _ in true }
        ) async {
            guard controller.areActivitiesEnabled else { return }

            let dose = MedicationLiveActivityPlan.doseToSurface(
                medications: medications,
                intakes: intakes,
                now: now,
                isLiveActivityEnabled: isLiveActivityEnabled
            )
            let resolved = dose.map {
                MedicationLiveActivityPlan.isResolved(
                    medicationId: $0.medicationId,
                    scheduledFor: $0.scheduledFireDate,
                    intakes: intakes
                )
            }
            await applyLiveActivityDecision(
                controller: controller,
                dose: dose,
                isResolved: resolved ?? false,
                now: now
            )
        }

        /// Shared ActivityKit mutation step for both reconcile paths: applies
        /// the resolved plan decision (`dose` + whether today's intakes already
        /// resolved it) to the controller. Awaits inline so the background
        /// caller can block on the start before `setTaskCompleted`.
        @MainActor
        private static func applyLiveActivityDecision(
            controller: any MedicationLiveActivityReconciling,
            dose: MedicationLiveActivityPlan.DoseActivity?,
            isResolved: Bool,
            now: Date
        ) async {
            guard let dose else {
                // Nothing due in-window — end any leftover Activity so a
                // stale countdown doesn't linger. This is also the path a
                // dose taken on the WEB takes once a server refresh lands:
                // `doseToSurface` drops the now-taken dose → nothing remains
                // in-window → every running Activity ends (b181 — closes the
                // double-dose gap where the Lock-Screen kept showing "jetzt
                // nehmen" after a remote intake).
                await controller.endAll(dismissalPolicy: .immediate)
                return
            }
            // If today's intakes already resolved this dose
            // (taken/skipped), end with the confirmation frame.
            // Otherwise (re)start/update the pending countdown.
            if isResolved {
                await controller.end(
                    medicationId: dose.medicationId,
                    finalStatus: .taken,
                    countdownTarget: now,
                    dismissalPolicy: .default
                )
            } else {
                await controller.start(
                    medicationId: dose.medicationId,
                    medicationName: dose.medicationName,
                    doseText: dose.doseText,
                    scheduledFireDate: dose.scheduledFireDate,
                    // W-B183 — carry the server-gated overdue verdict the
                    // pure plan computed (mirrors the in-app card) so the
                    // widget renders danger styling from the SAME truth, not
                    // its own `Date.now > countdownTarget`.
                    isOverdue: dose.isOverdue,
                    now: now
                )
            }
        }

        /// **v0.16.1 W-LA-BG** — wire the background Live-Activity reconcile hook.
        ///
        /// On every guaranteed-sync `BGProcessingTask` wakeup (after the
        /// med-store reconcile force-loads the current intakes) this reconciles
        /// the medication Live Activity **inline-awaited**, so a dose that
        /// became due while the app was backgrounded for hours gets its Live
        /// Activity STARTED — fixing the operator-reported "LA only appears
        /// after I open + re-background the app" gap. The controller + store are
        /// `@MainActor`, so the `@Sendable` hook hops onto the main actor; the
        /// weak captures make a torn-down container a harmless no-op.
        static func wireLiveActivityBackgroundReconcile(
            backgroundSync: BackgroundSyncCoordinator,
            controller: MedicationLiveActivityController,
            medicationsStore: MedicationsStore,
            deliveryPreferences: DeliveryPreferencesStore
        ) {
            backgroundSync.attachLiveActivityReconcileHook { [weak controller, weak medicationsStore, weak deliveryPreferences] in
                await performBackgroundLiveActivityReconcile(
                    controller: controller,
                    medicationsStore: medicationsStore,
                    deliveryPreferences: deliveryPreferences
                )
            }
        }

        /// `@MainActor` body of the background reconcile hook. Reads the live
        /// store snapshot on the main actor and **awaits** the inline reconcile
        /// so the BGTask blocks on the ActivityKit mutation. A torn-down
        /// container (any weak ref `nil`) is a harmless no-op.
        @MainActor
        private static func performBackgroundLiveActivityReconcile(
            controller: MedicationLiveActivityController?,
            medicationsStore: MedicationsStore?,
            deliveryPreferences: DeliveryPreferencesStore?
        ) async {
            guard let controller, let medicationsStore, let deliveryPreferences else { return }
            await reconcileMedicationLiveActivityAwaiting(
                controller: controller,
                medications: medicationsStore.medications,
                intakes: medicationsStore.todayIntakes,
                isLiveActivityEnabled: deliveryPreferences.enabledPredicate(for: .liveActivity)
            )
        }
    }
#endif
