import Foundation

extension AppContainer {
    /// Silences the local reminder of every slot the today list reports as
    /// taken or skipped, whichever surface recorded it, and puts a reminder
    /// back for a slot that opens again before its time
    /// (``MedicationReminderReopen``). Composes onto `onIntakesDidChange`,
    /// which every store load, every mark, undo and rollback reaches.
    static func wireReminderCompletion(medicationsStore: MedicationsStore) {
        #if canImport(Spezi) && canImport(SpeziScheduler)
            let previous = medicationsStore.onIntakesDidChange
            medicationsStore.onIntakesDidChange = { [weak medicationsStore] in
                previous?()
                guard let medicationsStore else { return }
                let intakes = medicationsStore.derivedTodayIntakes
                // D3 #4: other days' resolved slots too.
                MedicationReminderCompletion.completeReminders(
                    for: medicationsStore.allResolvedSlots,
                    accountTimeZone: medicationsStore.profileTimeZone
                )
                let plan = MedicationReminderReopen.advance(
                    resolved: MedicationReminderReopen.resolvedSlots(in: intakes),
                    open: MedicationReminderReopen.openSlots(in: intakes),
                    now: .now
                )
                MedicationReminderReopen.apply(
                    plan,
                    medications: medicationsStore.medications,
                    plansLocally: medicationsStore.localPlanningGate?() ?? true
                )
            }
        #endif
    }

    /// **#189 (2, 3)** — on every intake change, withdraw the delivered banner
    /// and the snooze or reopen reminder of each slot the today list reports
    /// as taken or skipped. The completion above only re-plans Spezi's
    /// *pending* requests: a banner that fired at 08:00 stayed on the lock
    /// screen and the Watch with its "Taken" button after a take at 08:10, and
    /// a snooze fired 15 minutes after the pill box had recorded the dose.
    static func wireResolvedReminderWithdrawal(medicationsStore: MedicationsStore) {
        #if canImport(UserNotifications)
            let previous = medicationsStore.onIntakesDidChange
            medicationsStore.onIntakesDidChange = { [weak medicationsStore] in
                previous?()
                guard let medicationsStore else { return }
                ResolvedReminderWithdrawal.withdraw(
                    doses: resolvedDoses(of: medicationsStore.allResolvedSlots),
                    pending: .outsideScheduler
                )
            }
        #endif
    }

    /// Today's taken or skipped slots as resolved doses.
    nonisolated static func resolvedDoses(in intakes: [MedicationIntake]) -> [ResolvedDose] {
        resolvedDoses(of: MedicationReminderCompletion.resolvedSlots(in: intakes))
    }

    /// Resolved slots as resolved doses.
    nonisolated static func resolvedDoses(of slots: [MedicationReminderCompletion.ResolvedSlot]) -> [ResolvedDose] {
        slots.map { ResolvedDose(medicationId: $0.medicationId, slotAt: $0.scheduledAt) }
    }
}

extension AppContainer {
    /// D3 #4 — every settled medications list reads the window for the
    /// medications whose cadence is not daily.
    static func wireResolvedBeyondToday(medicationsStore: MedicationsStore) {
        let previous = medicationsStore.onMedicationsListSettled
        medicationsStore.onMedicationsListSettled = { [weak medicationsStore] medications in
            previous?(medications)
            let ids = medications.filter(MedicationsStore.needsResolvedWindow).map(\.id)
            guard !ids.isEmpty else { return }
            _Concurrency.Task { @MainActor [weak medicationsStore] in
                await medicationsStore?.refreshResolvedSlotsBeyondToday(for: ids)
            }
        }
    }
}
