import Foundation

// MARK: - Which device plans the local reminders

extension AppContainer {
    /// Connects ``ReminderPlanningCoordinator`` to every local planner and to the
    /// `clientManaged` claim.
    ///
    /// - The medication store, the delivery preferences (Live Activity and
    ///   AlarmKit predicates) and the notification service (mood reminder,
    ///   supply alert) read the gate when they arm. On a phone it is always
    ///   open.
    /// - Each medication load asks the coordinator to re-read the device list
    ///   (throttled inside it), so an iPad notices an iPhone appearing or going
    ///   quiet at the next foreground.
    /// - When the answer flips, the planners run again at once: the medication
    ///   reconcile (which also reconciles the Live Activity), the mood reminder,
    ///   and the claim evaluation.
    func wireReminderPlanning() {
        let planning = reminderPlanning
        let gate: @MainActor () -> Bool = { [weak planning] in planning?.plansLocally ?? true }
        medicationsStore.localPlanningGate = gate
        deliveryPreferencesStore.localPlanningGate = gate
        #if canImport(UserNotifications) && canImport(UIKit)
            notifications.plansLocalReminders = gate
        #endif

        let previous = medicationsStore.onMedicationsDidChange
        medicationsStore.onMedicationsDidChange = { [weak planning] medications in
            previous?(medications)
            planning?.requestRefresh()
        }

        // A new account decides afresh as soon as its session is admitted.
        authenticatedSessionRegistry.observeAdmissions { [weak planning] _ in
            Task { @MainActor in await planning?.refresh(force: true) }
        }

        planning.onPlanningChanged = { [weak self] in
            guard let self else { return }
            medicationsStore.reconcileSpeziSchedulerIfAvailable()
            medicationReminderDelivery.noteLocalPlanningChanged()
            #if canImport(UserNotifications) && canImport(UIKit)
                #if canImport(ActivityKit)
                    // The Live Activity push token follows the decision too.
                    let service = notifications
                    Task { await service.reRegisterForLiveActivityTokenChange() }
                #endif
                let enabled = settingsStore.profile?.moodReminderEnabled ?? false
                let moodService = notifications
                Task { await moodService.reconcileMoodReminder(enabled: enabled, hour: MoodReminderPrefStore.hour()) }
            #endif
        }
    }
}
