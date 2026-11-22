import Foundation
import UserNotifications
import WidgetKit

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
    /// Set while the #189 cleanup runs; it owns the single delivery then.
    private var pendingDelivery: Delivery?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler deliverToSystem: @escaping (UNNotificationContent) -> Void
    ) {
        // "Hide content in notifications": whatever path below finishes, the
        // system stores only the neutral text. The secret relay category is
        // read once, here, so a reminder keeps its kind.
        let hideContent = NotificationContentPrivacy.isOn()
        let secretCategory = hideContent ? RelayKeyring.production()
            .secretCategory(for: MedicationReminderRedactor.medicationCategory) : nil
        let contentHandler: (UNNotificationContent) -> Void = { content in
            deliverToSystem(NotificationContentPrivacy.scrubbed(content, secretMedicationCategory: secretCategory, isOn: hideContent))
        }
        PushDeliveryCounters().note(.received, pushClass: .alert)
        self.contentHandler = contentHandler

        // #190 5.3: with the relay on, nothing outside the envelope is shown.
        // Until it opens, the fallback is the placeholder. D1 (8): a push that
        // carries an envelope always takes this way, whatever the flag says.
        if RelayEnvelopeMode.isOn() || request.content.userInfo[RelayNotificationRebuilder.envelopeKey] != nil {
            bestAttemptContent = RelayNotificationHandling.placeholder()
            RelayNotificationHandling.handle(request, handler: contentHandler) { content in
                let delivery = Delivery(content: content, handler: contentHandler)
                pendingDelivery = delivery
                return delivery
            }
            return
        }

        PushDeliveryCounters().note(.opened, pushClass: .alert)
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            // Non-mutable content (should not happen for an alert push):
            // deliver the original untouched.
            contentHandler(request.content)
            return
        }
        bestAttemptContent = mutable

        let eventType = mutable.userInfo["eventType"] as? String
        // #189 (1): a dose recorded elsewhere withdraws its reminders here,
        // with no app process, before the confirmation is shown.
        if eventType == MedicationIntakeRecordedPush.eventType {
            let delivery = Delivery(content: mutable, handler: contentHandler)
            pendingDelivery = delivery
            IntakeRecordedHandling.handle(mutable, deliver: delivery)
            return
        }
        let resolved = MedicationReminderRedactor.redactedContent(
            title: mutable.title,
            body: mutable.body,
            category: mutable.categoryIdentifier,
            eventType: eventType,
            hideMedicationName: LockScreenPrivacy.hideMedicationName(),
            placeholderTitle: String(localized: "notif.med.redacted.title"),
            placeholderBody: String(localized: "notif.med.redacted.body"),
            lowStockPlaceholderTitle: String(localized: "med.lowstock.push.title"),
            lowStockPlaceholderBody: String(localized: "med.lowstock.push.body.hidden")
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
        if let pendingDelivery {
            pendingDelivery.finish()
            return
        }
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}

/// Hands the content to the system exactly once, whichever path finishes
/// first (the cleanup or `serviceExtensionTimeWillExpire`). `@unchecked`:
/// the content and the handler are touched only under the lock, and the
/// handler is called at most once.
final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var content: UNMutableNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?

    init(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    func finish() {
        lock.lock()
        let pending = content.flatMap { content in handler.map { ($0, content) } }
        content = nil
        handler = nil
        lock.unlock()
        if let (handler, content) = pending { handler(content) }
    }
}

/// **#189 (1) — the `MEDICATION_INTAKE_RECORDED` confirmation push.**
///
/// The phone's reminders are local: a repeating SpeziScheduler trigger fires
/// without an app process, and only a running app withdrew it. This extension
/// runs for the server's passive confirmation instead (server 1.49.0, stable
/// in #191: `mutable-content: 1`, `interruption-level: passive`,
/// `thread-id: medication-<id>`) and, for a take and for a skip alike,
///
/// - writes the resolved slot to the App Group (``ResolvedDoseLedger``),
/// - removes the delivered banners of that dose (Spezi, snooze, reopen),
/// - removes its pending requests; a repeating trigger becomes single
///   requests for the following days (``ResolvedReminderPlan/carryDates``),
///   which the app's next scheduler pass replaces with the repeating one,
/// - reloads the widgets, whose provider reads the ledger,
/// - and shows the confirmation without the medication name.
///
/// Behind ``MedicationIntakeRecordedGate`` (the `medicationIntakeRecordedPush`
/// capability); with the gate shut the push shows the generic text.
enum IntakeRecordedHandling {
    /// The plaintext APNs path: the payload is the push's `userInfo`.
    static func handle(_ content: UNMutableNotificationContent, deliver: Delivery) {
        handle(payload: content.userInfo, content: content, deliver: deliver)
    }

    /// **Entry for a payload that did not arrive as `userInfo`**, such as the
    /// opened envelope of the push relay (#190). `payload` is the decrypted
    /// plaintext dictionary (`eventType`, `medicationId`, `intakeId`,
    /// `slotInstant`, `outcome`, `takenAt`, `takenVia`); `content` is the
    /// notification the extension delivers, already reset by the caller. Only
    /// fields from `payload` are written into it. `deliver` is finished exactly
    /// once, after the reminders are withdrawn.
    static func handle(payload: [AnyHashable: Any], content: UNMutableNotificationContent, deliver: Delivery) {
        content.title = String(localized: "notif.intake.recorded.title")
        guard MedicationIntakeRecordedGate.isOpen(),
              let dose = MedicationIntakeRecordedPush.parse(userInfo: payload) else
        {
            content.body = String(localized: "notif.intake.recorded.body.generic")
            deliver.finish()
            return
        }
        if !dose.wasTaken { content.title = String(localized: "notif.intake.skipped.title") }
        content.body = body(for: dose)
        content.threadIdentifier = MedicationIntakeRecordedPush.threadIdentifier(medicationId: dose.medicationId)
        content.interruptionLevel = .passive
        ResolvedDoseLedger().record(dose)
        ResolvedReminderWithdrawal.withdraw(doses: [dose], pending: .includingScheduler) {
            WidgetCenter.shared.reloadAllTimelines()
            deliver.finish()
        }
    }

    /// "Taken at 07:12 (pill box)" or "Skipped on another device" — never
    /// the medication's name.
    static func body(for dose: ResolvedDose) -> String {
        guard dose.wasTaken else { return String(localized: "notif.intake.skipped.body") }
        guard let takenAt = dose.takenAt else { return String(localized: "notif.intake.recorded.body.generic") }
        let time = takenAt.formatted(date: .omitted, time: .shortened)
        guard let source = sourceLabel(dose.source) else {
            return String(format: String(localized: "notif.intake.recorded.body.time"), time)
        }
        return String(format: String(localized: "notif.intake.recorded.body.time_source"), time, source)
    }

    /// `takenVia` (#191, final); an unknown value is "another device".
    static func sourceLabel(_ raw: String?) -> String? {
        switch MedicationTakenVia(wire: raw) {
        case .web: String(localized: "notif.intake.source.web")
        case .app: String(localized: "notif.intake.source.iphone")
        case .integration: String(localized: "notif.intake.source.integration")
        case .telegram: String(localized: "notif.intake.source.telegram")
        case .appleHealth: String(localized: "notif.intake.source.apple_health")
        case .importer: String(localized: "notif.intake.source.import")
        case .auto: String(localized: "notif.intake.source.auto")
        case .other: String(localized: "notif.intake.source.other")
        case nil: nil
        }
    }
}
