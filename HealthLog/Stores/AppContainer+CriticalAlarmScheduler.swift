import Foundation

extension AppContainer {
    /// **Critical-med AlarmKit reconcile pass (coexistence =
    /// REPLACE).**
    ///
    /// Runs in the same `MedicationsStore.load() → .fresh` completion arm as
    /// the Spezi scheduler reconcile, **before** it. Routes the medication
    /// set into the AlarmKit-owned meds (iOS≥26 + authorized + per-med
    /// critical-alarm ON + any cadence with a concrete next occurrence —
    /// v0.10 R1 §3.5: recurring weekly slots stay recurring, rolling/monthly/
    /// yearly/biweekly land as single-shot fixed alarms) and the rest,
    /// schedules/cancels the AlarmKit alarms, and returns the UNNotification/
    /// Spezi-bound subset so the alarm-owned meds are **excluded** from the
    /// existing scheduler — they can't double-fire.
    ///
    /// When AlarmKit isn't linked this returns the full medication set
    /// unchanged, so the call-site needs no branch and
    /// the existing UNNotification path is byte-for-byte unchanged.
    ///
    /// - Parameters:
    ///   - medications: the freshly-loaded medication snapshot.
    ///   - alarmEnabled: per-med critical-alarm opt-in predicate
    ///     (`DeliveryPreferencesStore.enabledPredicate(for: .criticalAlarm)`).
    ///   - onSchedulingFailures: **audit-release 05 C-1** — invoked (on the
    ///     MainActor, once the async reconcile settles) with the set of
    ///     medication ids whose critical alarm failed to arm on this pass —
    ///     empty on full success. The `MedicationsStore` threads this into a
    ///     persistent, user-visible warning so a missed life-safety alarm is
    ///     never invisible. Not called on non-AlarmKit builds, where
    ///     no alarm can be scheduled (nothing to fail).
    /// - Returns: the medications that stay on the UN/Spezi path.
    @MainActor
    static func reconcileCriticalAlarms(
        medications: [Medication],
        alarmEnabled: @escaping @Sendable (String) -> Bool,
        resolvedSlots: [MedicationReminderCompletion.ResolvedSlot] = [],
        accountTimeZone: TimeZone = .current,
        onSchedulingFailures: (@MainActor @Sendable (Set<String>) -> Void)? = nil
    ) -> [Medication] {
        #if canImport(AlarmKit)
            let authorized = CriticalMedAlarmService.shared.isAuthorized
            let (alarmMeds, unMeds) = CriticalMedAlarmRouting.route(
                medications: medications,
                alarmEnabled: alarmEnabled,
                authorized: authorized
            )
            // Schedule/cancel the AlarmKit alarms off the synchronous
            // store callback. Idempotent — a re-run with unchanged input
            // is a no-op at the AlarmKit layer. Thread the per-med
            // scheduling failures back so the store can surface them (an
            // empty set on success clears any prior warning).
            //
            // #188 (5): every intake change reconciles too now, so passes
            // overlap. Each one waits for the one before it: the inputs are
            // captured here, in call order, so the last pass (the freshest
            // intakes) is also the last to touch AlarmKit.
            let previous = criticalAlarmReconcileTail
            criticalAlarmReconcileTail = _Concurrency.Task { @MainActor in
                await previous?.value
                let outcome = await CriticalMedAlarmService.shared.reconcile(
                    alarmMeds: alarmMeds,
                    resolvedSlots: resolvedSlots,
                    accountTimeZone: accountTimeZone
                )
                onSchedulingFailures?(outcome.failedMedicationIDs)
            }
            return unMeds
        #else
            return medications
        #endif
    }

    /// "Hide medication names" changed. Each surface that baked the name in
    /// when it was planned is built again, so the switch holds from the tap
    /// on, not from the next dose: the app's own medication Live Activity
    /// (static attributes) ends and the reconcile starts it again under the
    /// new label, and the same reconcile re-arms the critical alarms and has
    /// Spezi plan its reminders anew (that refresh replaces every pending
    /// request). The relay Live Activity has its own lifecycle.
    @MainActor
    static func applyLockScreenPrivacyChange(
        endMedicationLiveActivities: @MainActor () async -> Void,
        replan: @MainActor () -> Void
    ) async {
        await endMedicationLiveActivities()
        replan()
    }

    @MainActor
    func applyLockScreenPrivacyChange() async {
        #if canImport(ActivityKit)
            let controller = medicationLiveActivityController
        #endif
        await Self.applyLockScreenPrivacyChange(
            endMedicationLiveActivities: {
                #if canImport(ActivityKit)
                    await controller.endAll(dismissalPolicy: .immediate)
                #endif
            },
            replan: { [medicationsStore] in medicationsStore.reconcileSpeziSchedulerIfAvailable() }
        )
    }

    /// The last critical-alarm reconcile started, which waits for every
    /// earlier one (``reconcileCriticalAlarms(medications:alarmEnabled:resolvedSlots:accountTimeZone:onSchedulingFailures:)``).
    @MainActor private static var criticalAlarmReconcileTail: Task<Void, Never>?

    /// Waits until every critical-alarm reconcile started so far has reached
    /// AlarmKit. The silent intake push awaits it so a dose taken elsewhere
    /// has its alarm suspended before the wake ends (#188 (3)).
    @MainActor
    static func criticalAlarmReconcilesSettled() async {
        await criticalAlarmReconcileTail?.value
    }

    /// **#188 (5)** — on every intake change, suspend today's critical alarm of
    /// each slot the today list reports as taken or skipped. The alarms were
    /// planned from the schedule alone and reconciled only when the
    /// medications changed, so a dose taken on the web still rang.
    static func wireCriticalAlarmIntakeSuspension(medicationsStore: MedicationsStore) {
        let previous = medicationsStore.onIntakesDidChange
        medicationsStore.onIntakesDidChange = { [weak medicationsStore] in
            previous?()
            medicationsStore?.reconcileCriticalAlarms()
        }
        // D3 #8 — an alarm's own Take or Snooze reloads and reconciles, and
        // waits until AlarmKit has the result before the intent returns.
        #if canImport(AlarmKit)
            MedicationAlarmActions.onAction = { [weak medicationsStore] in
                await medicationsStore?.load(force: true)
                await criticalAlarmReconcilesSettled()
            }
        #endif
    }
}
