import Foundation
import UserNotifications

/// **#190 5.3 — the extension's relay path.**
///
/// Runs for every remote notification once envelope mode is on. The content
/// the system handed over is discarded; what is shown is the placeholder or
/// what the envelope says. An opened notification is recorded in the verified
/// list, so a tap on it may act.
enum RelayNotificationHandling {
    static func placeholder() -> UNMutableNotificationContent {
        RelayNotificationRebuilder.placeholder(
            title: String(localized: "notif.relay.placeholder.title"),
            body: String(localized: "notif.relay.placeholder.body")
        )
    }

    /// Delivers through `deliver` or `handler`, exactly once.
    static func handle(
        _ request: UNNotificationRequest,
        handler: @escaping (UNNotificationContent) -> Void,
        startDelivery: (UNMutableNotificationContent) -> Delivery
    ) {
        let keyring = RelayKeyring.production()
        let opened = RelayNotificationRebuilder.open(
            userInfo: request.content.userInfo,
            pushClass: .alert,
            keyring: keyring,
            replayStore: RelayFileReplayStore()
        )
        guard case let .success(plaintext) = opened else {
            PushDeliveryCounters().note(.discarded, pushClass: .alert)
            handler(placeholder())
            return
        }
        PushDeliveryCounters().note(.opened, pushClass: .alert)
        RelayOpenedLedger().record(
            RelayNotificationRebuilder.ledgerEntry(for: plaintext, requestId: request.identifier, pushClass: .alert)
        )
        // #189 over the relay: the one call into the intake handler.
        if let payload = RelayIntakeBridge.payload(from: plaintext) {
            let content = placeholder()
            IntakeRecordedHandling.handle(payload: payload, content: content, deliver: startDelivery(content))
            return
        }
        // #190 5.6: the server's reminder arrived; the local fallback goes,
        // and stays gone when the app plans again (R1 (7)).
        if let dose = RelayFollowUps.slot(of: plaintext) {
            RelayDeliveredReminders().record(medicationId: dose.medicationId, slot: dose.slot)
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [RelayFollowUps.fallbackIdentifier(medicationId: dose.medicationId, slot: dose.slot)]
            )
        }
        let content = RelayNotificationRebuilder.content(
            for: plaintext,
            placeholderTitle: String(localized: "notif.relay.placeholder.title"),
            placeholderBody: String(localized: "notif.relay.placeholder.body"),
            secretCategory: { keyring.secretCategory(for: $0) }
        )
        // The lock-screen privacy choice applies to opened reminders as well.
        let resolved = MedicationReminderRedactor.redactedContent(
            title: content.title,
            body: content.body,
            category: plaintext.category ?? "",
            eventType: plaintext.type,
            hideMedicationName: LockScreenPrivacy.hideMedicationName(),
            placeholderTitle: String(localized: "notif.med.redacted.title"),
            placeholderBody: String(localized: "notif.med.redacted.body")
        )
        content.title = resolved.title
        content.body = resolved.body
        handler(content)
    }
}
