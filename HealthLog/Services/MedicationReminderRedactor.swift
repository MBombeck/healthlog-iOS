import Foundation

/// **AUDIT-v0162 H2 — pure medication-reminder redaction shared by the
/// Notification Service Extension (`NotificationService`) and the app.**
///
/// Given the visible push text (`title` / `body`), the push's category /
/// event-type marker, and the user's device-local "hide medication name"
/// opt-out (`LockScreenPrivacy`), this decides the lock-screen text to render:
/// either the original (passthrough) or a neutral localized placeholder that
/// hides the drug name + dose.
///
/// It is deliberately **pure** — Foundation-only, no `UNNotification*`, no
/// bundle / `String(localized:)` lookups (the caller resolves the localized
/// placeholders and passes them in). That keeps the decision unit-testable in
/// isolation and lets it compile into the NSE target without dragging app,
/// Spezi, or networking dependencies across the target boundary.
enum MedicationReminderRedactor {
    /// Category / event-type marker the server tags medication-reminder pushes
    /// with (`aps.category` == this and/or `userInfo.eventType` == this). MUST
    /// stay in lock-step with `NotificationService.categoryMedication` and the
    /// server APNs contract.
    static let medicationCategory = "MEDICATION_REMINDER"

    /// The low-supply push (`NotificationService.categoryMedicationLowStock`).
    /// It names the medication as well, so the same switch covers it.
    static let lowStockCategory = "MEDICATION_LOW_STOCK"

    /// Resolved lock-screen text (either passthrough or redacted).
    struct Content: Equatable {
        let title: String
        let body: String
    }

    /// `true` when a push carrying `category` / `eventType` is a medication
    /// reminder. With the low-supply push, the categories this NSE redacts;
    /// every other push passes through untouched.
    static func isMedicationReminder(category: String?, eventType: String?) -> Bool {
        category == medicationCategory || eventType == medicationCategory
    }

    /// `true` for the low-supply push, by category or event type.
    static func isLowStock(category: String?, eventType: String?) -> Bool {
        category == lowStockCategory || eventType == lowStockCategory
    }

    /// Pure redaction decision.
    ///
    /// - Returns the **original** `title` / `body` (passthrough) when the push
    ///   is not a medication reminder, or when the user has not opted in to
    ///   hiding the medication name.
    /// - Returns the neutral `placeholderTitle` / `placeholderBody` when the
    ///   med name must be hidden. The caller keeps the actionable `userInfo`
    ///   (medicationId / scheduleId / scheduledFor) intact — only the
    ///   human-readable PHI on the lock screen is replaced; the OS still shows
    ///   the delivery time.
    /// - A low-supply push takes `lowStockPlaceholderTitle` / `…Body` when
    ///   the caller has them, else the reminder placeholders: either way the
    ///   name is gone.
    static func redactedContent(
        title: String,
        body: String,
        category: String?,
        eventType: String?,
        hideMedicationName: Bool,
        placeholderTitle: String,
        placeholderBody: String,
        lowStockPlaceholderTitle: String? = nil,
        lowStockPlaceholderBody: String? = nil
    ) -> Content {
        guard hideMedicationName else { return Content(title: title, body: body) }
        if isMedicationReminder(category: category, eventType: eventType) {
            return Content(title: placeholderTitle, body: placeholderBody)
        }
        if isLowStock(category: category, eventType: eventType) {
            return Content(
                title: lowStockPlaceholderTitle ?? placeholderTitle,
                body: lowStockPlaceholderBody ?? placeholderBody
            )
        }
        return Content(title: title, body: body)
    }
}
