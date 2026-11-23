import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(AlarmKit)
    import AlarmKit
    import AppIntents

    // **AlarmKit critical-med alarm buttons → App Intents.**
    //
    // The AlarmKit breakthrough alert fires its buttons **out-of-process**
    // (the app may be suspended). Per the iOS 26.5 SDK, both `stopIntent`
    // and `secondaryIntent` on `AlarmManager.AlarmConfiguration` are typed
    // `(any AppIntents.LiveActivityIntent)?` — so these intents conform to
    // `LiveActivityIntent` (not plain `AppIntent`).
    //
    // Both route through the **same** server-first path the UNNotification
    // "Genommen"/"Snooze" actions + the Siri/widget "Genommen" button use:
    // `IntentDependencies.resolve()` → `MedicationsRepository.recordFrom-
    // Reminder(...)`, idempotency-keyed, Outbox fallback on a retriable
    // network error. No parallel write path. The `(medicationId,
    // scheduledFor)` parameters are primitives so the intent is
    // self-contained and survives app-not-running.

    /// Primary "Genommen" button — stops the alarm and records the dose
    /// taken against the server (or enqueues on the Outbox offline).
    struct MedTakenAlarmIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "med.dose.action.take"
        static let openAppWhenRun: Bool = false

        @Parameter(title: "Medication ID")
        var medicationId: String

        @Parameter(title: "Scheduled For")
        var scheduledFor: Date

        init() {}

        init(medicationId: String, scheduledFor: Date) {
            self.medicationId = medicationId
            self.scheduledFor = scheduledFor
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            let deps = IntentDependencies.resolve()
            guard IntentDependencies.isSignedIn(deps) else { return .result() }
            let idempotencyKey = IdempotencyKey()
            // D3 #6: the dose that rang, booked onto the account slot when the
            // phone is away from the account zone.
            let occurrence = CriticalMedAlarmRouting.occurrence(of: scheduledFor, now: .now)
            let booking = MedicationReminderSlot.booking(deliveredAt: occurrence)
            do {
                let receipt = try await deps.medicationsRepo.recordFromReminderReturningReceipt(
                    medicationId: medicationId,
                    scheduledFor: booking.pin ?? scheduledFor,
                    status: .taken,
                    forceSlotInstant: booking.pin,
                    idempotencyKey: idempotencyKey
                )
                // R1 (1): the undo finds exactly the row this tap wrote.
                ExternalTakeLog().record(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    source: .alarm,
                    binding: ExternalTakeLog.Binding.forCommit(error: nil, receipt: receipt, idempotencyKey: idempotencyKey.raw)
                )
            } catch let already as MedicationAlreadyTaken {
                // D3 #13: taken elsewhere already; nothing was recorded. The
                // alarm is gone, so a quiet notice says when the first dose was.
                await MedicationAlarmActions.confirmAlreadyTaken(already)
            } catch {
                // Retriable errors already enqueued on the Outbox inside
                // recordFromReminder; non-retriable are logged + swallowed so
                // the alarm still stops (the AlarmKit stop button dismisses
                // regardless of the intent result).
                HLLog.notifications.error(
                    "MedTakenAlarmIntent: recordFromReminder failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            // D3 #8: reload and reconcile, so a suspended weekday comes back.
            await MedicationAlarmActions.didAct()
            return .result()
        }
    }

    /// Secondary "Remind me later" button — re-arms a one-shot alarm after
    /// the account's snooze span (#191)
    /// (parity with the UNNotification snooze,
    /// `NotificationService.snoozeIntervalSeconds`). **No server call:** the
    /// bulk intake endpoint can't express a `.snoozed` status, so this intent
    /// only re-arms locally; the server intake row stays `pending` until the
    /// re-fired alarm is actioned ("Genommen" → `.taken`).
    struct MedSnoozeAlarmIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "alarm.action.snooze"
        static let openAppWhenRun: Bool = false

        @Parameter(title: "Medication ID")
        var medicationId: String

        @Parameter(title: "Scheduled For")
        var scheduledFor: Date

        @Parameter(title: "Medication Name")
        var medicationName: String

        @Parameter(title: "Dose")
        var dose: String

        init() {}

        init(medicationId: String, scheduledFor: Date, medicationName: String, dose: String) {
            self.medicationId = medicationId
            self.scheduledFor = scheduledFor
            self.medicationName = medicationName
            self.dose = dose
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            let deps = IntentDependencies.resolve()
            guard IntentDependencies.isSignedIn(deps) else { return .result() }
            // Re-arm a one-shot alarm after the snooze span. NO server call is made
            // here (matches the UN snooze): the bulk endpoint has no
            // `.snoozed` status, so the server intake row stays `pending`
            // until the re-fired alarm is actioned. The signed-in guard is
            // kept for parity with the taken-intent so a snooze on a
            // signed-out device is a no-op rather than re-arming an orphan.
            await CriticalMedAlarmService.shared.snooze(
                medicationId: medicationId,
                medicationName: medicationName,
                dose: dose,
                scheduledFor: scheduledFor
            )
            await MedicationAlarmActions.didAct()
            return .result()
        }
    }
#endif

/// **D3 #8 / #13 — what follows an action on a critical alarm.**
///
/// The alarm's buttons run their intent without the app on screen, and
/// nothing reloaded the medications afterwards: a weekday the alarm had left
/// out after a take in the app stayed out until the app ran again, so someone
/// who then only used the alarm lost that day's alarm for good. The app wires
/// ``onAction`` to a forced load, which reconciles the alarms; outside the
/// app process it stays `nil`.
@MainActor
enum MedicationAlarmActions {
    static var onAction: (@MainActor () async -> Void)?

    static func didAct() async {
        await onAction?()
    }

    #if canImport(UserNotifications)
        /// The quiet "Already taken at 07:12 (pill box)" notice, the same one a
        /// banner's Take shows (`NotificationService.confirmAlreadyTaken`).
        static func confirmAlreadyTaken(_ already: MedicationAlreadyTaken) async {
            do {
                try await UNUserNotificationCenter.current().add(alreadyTakenRequest(already))
            } catch {
                HLLog.notifications.error(
                    "alarm.taken: already-taken notice failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        nonisolated static func alreadyTakenRequest(_ already: MedicationAlreadyTaken) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "med.already_taken.title")
            content.body = already.message
            content.interruptionLevel = .passive
            return UNNotificationRequest(
                identifier: "med-already-taken-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        }
    #endif
}
