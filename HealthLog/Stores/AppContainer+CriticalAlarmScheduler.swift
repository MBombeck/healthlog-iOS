import Foundation

extension AppContainer {
    /// **v0.9.0 W2 — critical-med AlarmKit reconcile pass (coexistence =
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
    /// On iOS < 26 (or when AlarmKit isn't linked) this returns the full
    /// medication set unchanged, so the call-site needs no version branch and
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
    ///     never invisible. Not called on iOS < 26 / non-AlarmKit builds, where
    ///     no alarm can be scheduled (nothing to fail).
    /// - Returns: the medications that stay on the UN/Spezi path.
    @MainActor
    static func reconcileCriticalAlarms(
        medications: [Medication],
        alarmEnabled: @escaping @Sendable (String) -> Bool,
        onSchedulingFailures: (@MainActor @Sendable (Set<String>) -> Void)? = nil
    ) -> [Medication] {
        #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                let authorized = CriticalMedAlarmService.shared.isAuthorized
                let (alarmMeds, unMeds) = CriticalMedAlarmRouting.route(
                    medications: medications,
                    alarmEnabled: alarmEnabled,
                    authorized: authorized,
                    osAvailable: true
                )
                // Schedule/cancel the AlarmKit alarms off the synchronous
                // store callback. Idempotent — a re-run with unchanged input
                // is a no-op at the AlarmKit layer. C-1 — thread the per-med
                // scheduling failures back so the store can surface them (an
                // empty set on success clears any prior warning).
                _Concurrency.Task { @MainActor in
                    let outcome = await CriticalMedAlarmService.shared.reconcile(alarmMeds: alarmMeds)
                    onSchedulingFailures?(outcome.failedMedicationIDs)
                }
                return unMeds
            }
            return medications
        #else
            return medications
        #endif
    }
}
