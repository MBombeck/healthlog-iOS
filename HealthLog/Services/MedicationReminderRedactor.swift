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

    /// Resolved lock-screen text (either passthrough or redacted).
    struct Content: Equatable {
        let title: String
        let body: String
    }

    /// `true` when a push carrying `category` / `eventType` is a medication
    /// reminder — the only category this NSE redacts. Every other push passes
    /// through untouched.
    static func isMedicationReminder(category: String?, eventType: String?) -> Bool {
        category == medicationCategory || eventType == medicationCategory
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
    static func redactedContent(
        title: String,
        body: String,
        category: String?,
        eventType: String?,
        hideMedicationName: Bool,
        placeholderTitle: String,
        placeholderBody: String
    ) -> Content {
        guard hideMedicationName,
              isMedicationReminder(category: category, eventType: eventType) else
        {
            return Content(title: title, body: body)
        }
        return Content(title: placeholderTitle, body: placeholderBody)
    }
}
