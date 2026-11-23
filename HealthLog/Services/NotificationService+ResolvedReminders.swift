import Foundation
#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    extension NotificationService {
        /// **#189 (3)** — the snooze id follows from the medication and the
        /// slot, so a second snooze of the same dose replaces the first and a
        /// take elsewhere finds it (its `userInfo` names the slot too). A
        /// snooze without a slot keeps a random id.
        nonisolated static func snoozeIdentifier(medicationId: String?, scheduledFor: Date?) -> String {
            let medication = medicationId ?? "anon"
            guard let scheduledFor else { return "snooze-\(medication)-\(UUID().uuidString)" }
            return "snooze-\(medication)-\(Int(scheduledFor.timeIntervalSince1970))"
        }

        /// **#189 (4)** — whether a medication reminder arriving in the
        /// foreground names a slot that is already resolved: in today's list
        /// of the store, or in the App Group ledger the extension fills from
        /// the server's confirmation push. Such a reminder is not presented.
        func medicationReminderIsResolved(_ notification: UNNotification) -> Bool {
            let reminder = ResolvedReminderPlan.reminder(
                identifier: notification.request.identifier,
                userInfo: notification.request.content.userInfo,
                firesAt: notification.date
            )
            // 1.7: only entries newer than the store's last server answer;
            // the store's rows already carry everything older.
            let store = medicationsStoreAccessor?()
            var doses = ResolvedDoseLedger().entries(recordedAfter: store?.doseConfirmation.asOf)
            if let store {
                doses += AppContainer.resolvedDoses(of: store.allResolvedSlots)
            }
            return ResolvedReminderPlan.isResolved(reminder, by: doses)
        }

        /// **#189 (6)** — a take from the banner hit a slot already taken
        /// elsewhere. Nothing was recorded; a local confirmation says when the
        /// first dose was taken, since the app is not on screen to say it.
        func confirmAlreadyTaken(_ already: MedicationAlreadyTaken) async {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "med.already_taken.title")
            content.body = already.message
            content.interruptionLevel = .passive
            // Hide content in notifications: no time, no source in the store.
            NotificationContentPrivacy.apply(to: content, kind: .healthData)
            let request = UNNotificationRequest(
                identifier: "med-already-taken-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await addLocalNotification(request)
            } catch {
                HLLog.notifications.error(
                    "med.taken: already-taken confirmation failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }
#endif
