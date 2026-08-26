import UserNotifications

/// **AUDIT-v0162 H2 — Notification Service Extension that redacts the drug
/// name + dose on remote medication-reminder pushes when the device-local
/// "hide medication name on lock screen" opt-out (`LockScreenPrivacy`) is ON.**
///
/// Before this extension existed, a server-pushed `MEDICATION_REMINDER` alert
/// was rendered verbatim by the OS (`aps.alert.title/body` = drug name + dose),
/// so the in-app privacy toggle could not reach the primary (remote-push)
/// reminder path. This appex closes that gap locally:
///
/// 1. **The server MUST send `mutable-content: 1`** on medication-reminder
///    pushes — that flag is what makes iOS invoke this extension. Until the
///    server sends it, this appex never fires and the OS renders the original
///    alert (SERVER-COORD item; the appex is a no-op until then).
/// 2. It reads the opt-out from the SHARED App-Group `UserDefaults`
///    (`group.dev.healthlog.app`) — the same suite the app writes the toggle
///    to (`LockScreenPrivacy.setHideMedicationName`).
/// 3. For `MEDICATION_REMINDER` pushes only (gated on `aps.category` /
///    `userInfo.eventType`), it replaces the visible `title`/`body` with a
///    neutral localized placeholder. `userInfo` (medicationId / scheduleId /
///    scheduledFor) is left intact so the 3-action intake chrome keeps
///    working. Every other push passes through unchanged.
///
/// The pure redaction decision lives in `MedicationReminderRedactor` (unit-
/// tested in `HealthLogTests`); this class is only the thin `UNNotification*`
/// adapter + the localized-placeholder resolution + the time-expiry fallback.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler

        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            // Non-mutable content (should not happen for an alert push):
            // deliver the original untouched.
            contentHandler(request.content)
            return
        }
        bestAttemptContent = mutable

        let eventType = mutable.userInfo["eventType"] as? String
        let resolved = MedicationReminderRedactor.redactedContent(
            title: mutable.title,
            body: mutable.body,
            category: mutable.categoryIdentifier,
            eventType: eventType,
            hideMedicationName: LockScreenPrivacy.hideMedicationName(),
            placeholderTitle: String(localized: "notif.med.redacted.title"),
            placeholderBody: String(localized: "notif.med.redacted.body")
        )
        // `redactedContent` returns the originals on passthrough, so this is a
        // safe unconditional assign for both the redacted and passthrough case.
        mutable.title = resolved.title
        mutable.body = resolved.body

        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        // Best-effort fallback if the system is about to kill the extension.
        // Our redaction is synchronous + instant, so `bestAttemptContent` is
        // already the redacted (or passthrough) content by the time we get
        // here; deliver it rather than dropping the notification.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
