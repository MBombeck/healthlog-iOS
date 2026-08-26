#if canImport(AlarmKit)
    import AlarmKit
    import AppIntents
    import Foundation

    // **v0.9.0 W3 — AlarmKit critical-med alarm buttons → App Intents.**
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
    @available(iOS 26.0, *)
    struct MedTakenAlarmIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "alarm.action.taken"
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
            do {
                try await deps.medicationsRepo.recordFromReminder(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    status: .taken
                )
            } catch {
                // Retriable errors already enqueued on the Outbox inside
                // recordFromReminder; non-retriable are logged + swallowed so
                // the alarm still stops (the AlarmKit stop button dismisses
                // regardless of the intent result).
                HLLog.notifications.error(
                    "MedTakenAlarmIntent: recordFromReminder failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            return .result()
        }
    }

    /// Secondary "Snooze" button — re-arms a one-shot alarm 15 min later
    /// (parity with the UNNotification snooze,
    /// `NotificationService.snoozeIntervalSeconds`). **No server call:** the
    /// bulk intake endpoint can't express a `.snoozed` status, so this intent
    /// only re-arms locally; the server intake row stays `pending` until the
    /// re-fired alarm is actioned ("Genommen" → `.taken`).
    @available(iOS 26.0, *)
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
            // Re-arm a one-shot alarm 15 min later. NO server call is made
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
            return .result()
        }
    }
#endif
