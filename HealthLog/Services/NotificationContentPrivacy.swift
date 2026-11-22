import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// **"Hide content in notifications" — nothing about a dose or a value
/// reaches the system's notification store.**
///
/// iOS keeps every delivered notification's title and body in its own
/// database on the device, and that database outlives the app's own data
/// (deleted chats have been read back from it). With this option on, every
/// notification HealthLog shows carries a neutral text only: the extension
/// rewrites each relay and direct push after it opened it, and the app writes
/// its local reminders with the same text. The actions and `userInfo` stay, so
/// Taken / Snooze / Skip and the tap keep working.
///
/// It extends ``LockScreenPrivacy``: content hidden means names hidden too,
/// so every surface that already honours "hide names" (Live Activity, widget,
/// banner rewrite) follows. **Default off**; an update changes nothing until
/// the person turns it on. Device-local, in the shared App Group suite the
/// extension reads.
enum NotificationContentPrivacy {
    static let hideContentKey = LockScreenPrivacy.hideNotificationContentKey

    /// What a neutral text says.
    enum Kind: Sendable, Equatable {
        /// A reminder of any kind (dose, mood, measurement, snooze, fallback).
        case reminder
        /// Something about the person's health data (a recorded dose, a
        /// reading outside a range, a low supply, new data on the server).
        case healthData
        /// Everything else.
        case generic
    }

    static func isOn(defaults: UserDefaults = LockScreenPrivacy.sharedDefaults) -> Bool {
        defaults.bool(forKey: hideContentKey)
    }

    static func set(_ on: Bool, defaults: UserDefaults = LockScreenPrivacy.sharedDefaults) {
        defaults.set(on, forKey: hideContentKey)
    }

    /// The neutral title and body for `kind`. The caller's bundle resolves the
    /// keys, so the extension reads its own catalog.
    static func neutralText(for kind: Kind) -> (title: String, body: String) {
        let title = String(localized: "notif.privacy.neutral.title")
        switch kind {
        case .reminder: return (title, String(localized: "notif.privacy.neutral.reminder"))
        case .healthData: return (title, String(localized: "notif.privacy.neutral.healthData"))
        case .generic: return (title, String(localized: "notif.privacy.neutral.generic"))
        }
    }

    /// The kind of a push or local notification, from its category and the
    /// `eventType` it carries.
    static func kind(category: String?, eventType: String?, secretMedicationCategory: String? = nil) -> Kind {
        let reminders: Set<String> = [MedicationReminderRedactor.medicationCategory, "MOOD_REMINDER", "MEASUREMENT_REMINDER"]
        if let category, reminders.contains(category) || (secretMedicationCategory != nil && category == secretMedicationCategory) {
            return .reminder
        }
        if let eventType, reminders.contains(eventType) || eventType.hasSuffix("_REMINDER") { return .reminder }
        let data: Set = ["MEDICATION_INTAKE_RECORDED", "DATA_CHANGED", "MEDICATION_LOW_STOCK", "THRESHOLD_NUDGE"]
        if let eventType, data.contains(eventType) { return .healthData }
        if let category, data.contains(category) { return .healthData }
        return .generic
    }

    #if canImport(UserNotifications)
        /// Rewrites `content` to the neutral text when the option is on; a
        /// no-op otherwise. The subtitle and attachments go too, as they can
        /// carry a name.
        static func apply(to content: UNMutableNotificationContent, kind: Kind, isOn: Bool = NotificationContentPrivacy.isOn()) {
            guard isOn else { return }
            let neutral = neutralText(for: kind)
            content.title = neutral.title
            content.subtitle = ""
            content.body = neutral.body
            content.attachments = []
        }

        /// The delivered form of `content`: a copy with the neutral text when
        /// the option is on, else `content` itself.
        static func scrubbed(
            _ content: UNNotificationContent,
            secretMedicationCategory: String? = nil,
            isOn: Bool = NotificationContentPrivacy.isOn()
        ) -> UNNotificationContent {
            guard isOn, let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
            let kind = kind(
                category: mutable.categoryIdentifier,
                eventType: mutable.userInfo["eventType"] as? String,
                secretMedicationCategory: secretMedicationCategory
            )
            apply(to: mutable, kind: kind, isOn: true)
            return mutable
        }
    #endif
}
