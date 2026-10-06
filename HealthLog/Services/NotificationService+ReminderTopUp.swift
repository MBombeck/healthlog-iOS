#if canImport(UserNotifications) && canImport(UIKit)
    import Foundation

    extension NotificationService {
        /// The actions on a medication reminder banner.
        static let medicationReminderActionIDs: Set<String> = [
            actionMedicationTaken,
            actionMedicationSnooze,
            actionMedicationSkipped
        ]

        /// **R5** — an action on a medication reminder (Genommen, Überspringen,
        /// Verschieben) runs in the background without opening the app. It is
        /// often the only time the app runs for days, so after the action it
        /// extends the local reminder runway from the cached medication list
        /// (no request). Every other action is left alone.
        @MainActor
        func topUpAfterReminderAction(_ actionID: String) async {
            guard Self.medicationReminderActionIDs.contains(actionID) else { return }
            await backgroundSync?.runReminderTopUp()
        }
    }
#endif
