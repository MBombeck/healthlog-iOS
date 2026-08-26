import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// Notification category + action identifier registry split out of
    /// `NotificationService.swift` (file_length discipline — pure move, no
    /// behaviour change). The identifiers MUST match the server-side
    /// `aps.category` payloads.
    @MainActor
    extension NotificationService {
        // MARK: - Categories (S3 / v0.4.1 / v0.5.3 F-4)

        /// Identifiers MUST match server-side payload `aps.category`:
        ///   - "MEDICATION_REMINDER"  → 3 actions (Genommen, Snooze 15 min, Übersprungen)
        ///   - "DAILY_BRIEFING_NUDGE" → öffnen (foreground)
        ///   - "MOOD_REMINDER"        → 3 actions (Stimmung erfassen, Snooze 1h, Heute überspringen)
        ///
        /// (v0.5.0+ R1: STREAK_REMINDER was removed alongside the dashboard
        /// streak feature. No category, no action, no payload variant.)
        ///
        /// Server-side payload should set `interruption-level: time-sensitive`
        /// for medication reminders so iOS surfaces them through Focus modes.
        /// (Server already does — see Foxtrot v0.4.0).
        ///
        /// v0.5.3 F-4: action set redesigned to the operator-mandated
        /// trio. "Genommen" + "Übersprungen" both hit the server bulk-
        /// intake endpoint via `MedicationsRepository.recordFromReminder`.
        /// "Snooze 15 Min" re-schedules locally without touching the
        /// server (snooze is client-state). Server-Coord-Required: the
        /// APNs sender (`src/lib/notifications/senders/apns.ts`) must set
        /// `aps.category = "MEDICATION_REMINDER"` and emit
        /// `medicationId` + `scheduleId` + `scheduledFor` at the top
        /// level of `userInfo` — without those the action buttons render
        /// but the handler falls through to a deep-link only.
        ///
        /// v0.5.4.3 HP5: MOOD_REMINDER category added in lock-step with
        /// server PR #190 which introduces the daily mood-reminder cron
        /// + `MOOD_REMINDER` event type. "Stimmung erfassen" deep-links
        /// to the central-CTA `MoodQuickEntrySheet`. "Snooze 1h"
        /// re-schedules locally (no server roundtrip — server has no
        /// "snoozed mood reminder" concept). "Heute überspringen" is
        /// client-only because the server has no dismiss endpoint —
        /// the next day's 22:00 cron tick fires normally.
        nonisolated static let categoryMedication = "MEDICATION_REMINDER"
        /// Low-supply heads-up. Deliberately a SEPARATE category from
        /// `categoryMedication` with **no intake actions** — a supply alert must
        /// never expose a "Taken" button (tapping it would record a phantom
        /// intake the user never took; W-B185 senior-audit HIGH). A body-tap
        /// deep-links to the supply section via `medicationId`.
        nonisolated static let categoryMedicationLowStock = "MEDICATION_LOW_STOCK"
        nonisolated static let categoryBriefing = "DAILY_BRIEFING_NUDGE"
        nonisolated static let categoryMood = "MOOD_REMINDER"
        /// W-B189 (#23) — preventive-care (Vorsorge) reminder. The server rides
        /// the generic APNs category today (plain-alert fallback); this dedicated
        /// category adds an "Erledigt"/complete action for parity with the
        /// med/mood reminder pattern. The identifier MUST match the server-side
        /// `aps.category` once the server tags `MEASUREMENT_REMINDER` pushes with
        /// it. A body-tap deep-links to the relevant measurement capture via the
        /// server-supplied `deepLink` (else falls through to the dashboard).
        nonisolated static let categoryMeasurementReminder = "MEASUREMENT_REMINDER"
        /// v1.18.4 (#23/#30) — server `SYSTEM_ALERT` event type. Carries the
        /// illness red-flag "seek care" escalation; when urgent it rides
        /// `aps.interruption-level: time-sensitive` (or `critical` when the
        /// operator's `APNS_CRITICAL_ENTITLEMENT` is set). The foreground
        /// presentation policy elevates it (`foregroundPresentationOptions`).
        nonisolated static let categorySystemAlert = "SYSTEM_ALERT"
        /// **W-THRESHOLD-NUDGE (v0.15.2)** — client-side out-of-range nudge. A
        /// PURELY INFORMATIONAL, retrospective banner fired locally when a
        /// just-logged reading falls outside a server / user-defined range AND
        /// the server has not already escalated it. No actions — a body-tap only
        /// deep-links to the labs surface for context. This is NOT a server
        /// `aps.category`: it is local-only and deliberately distinct from the
        /// server's `MEASUREMENT_ANOMALY` escalation (the client defers to that).
        nonisolated static let categoryThresholdNudge = "THRESHOLD_NUDGE"

        /// New v0.5.3 F-4 identifiers. The legacy `MED_LOGGED` /
        /// `MED_SNOOZE_10` strings are gone — pending pushes already
        /// queued under the old identifiers will hit the fallback
        /// `default` branch in the handler (deep-link to the
        /// medication detail) rather than crash.
        static let actionMedicationTaken = "med.taken"
        static let actionMedicationSnooze = "med.snooze.15m"
        static let actionMedicationSkipped = "med.skipped"
        static let actionBriefingOpen = "BRIEFING_OPEN"

        /// v0.5.4.3 HP5 — mood-reminder action identifiers. Mirror the
        /// medication-action shape but with longer snooze (1h vs 15min)
        /// because mood logging is less time-sensitive than a dose.
        static let actionMoodLogNow = "mood.log.now"
        static let actionMoodSnooze = "mood.snooze.1h"
        static let actionMoodDismiss = "mood.dismiss"

        /// W-B189 (#23) — preventive-care reminder "Erledigt"/complete action.
        /// Foreground so the tap opens the app onto the measurement capture
        /// surface. There is no confirmed server completion route in the v1.17.1
        /// contract (the server only asked for the category for parity), so the
        /// handler routes the body-tap deep-link to capture rather than POSTing a
        /// server "done" — see `NotificationService+MeasurementReminder.swift`.
        static let actionMeasurementDone = "measurement.done"

        /// Snooze interval used by the snooze action — surfaced as a
        /// static so tests can assert the trigger without re-deriving
        /// the value.
        static let snoozeIntervalSeconds: TimeInterval = 15 * 60

        /// Mood-snooze interval — longer than med-snooze because the
        /// 22:00 mood-reminder doesn't compete with a time-locked dose.
        /// One hour parks the prompt into the wind-down window without
        /// crashing the user's bedtime.
        static let moodSnoozeIntervalSeconds: TimeInterval = 60 * 60

        func registerCategories() {
            let medication = UNNotificationCategory(
                identifier: Self.categoryMedication,
                actions: [
                    // "Genommen" — primary positive action. Foreground
                    // option keeps the banner dismissed silently; the
                    // server-roundtrip runs inside the handler before we
                    // surrender the background runtime. No
                    // authentication-required flag because the user
                    // already authenticated to wake the phone, and the
                    // action is undo-able from the Today section.
                    UNNotificationAction(
                        identifier: Self.actionMedicationTaken,
                        title: String(localized: "Taken"),
                        options: []
                    ),
                    UNNotificationAction(
                        identifier: Self.actionMedicationSnooze,
                        title: String(localized: "Snooze 15 min"),
                        options: []
                    ),
                    // "Übersprungen" — flagged destructive so iOS
                    // surfaces it in red on the long-press menu. The
                    // semantic isn't strictly destructive (no row is
                    // deleted), but the affordance is "I will NOT take
                    // this dose" which the red treatment communicates
                    // far more clearly than a plain action.
                    UNNotificationAction(
                        identifier: Self.actionMedicationSkipped,
                        title: String(localized: "med.card.action.skipped"),
                        options: [.destructive]
                    )
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            let briefing = UNNotificationCategory(
                identifier: Self.categoryBriefing,
                actions: [
                    UNNotificationAction(
                        identifier: Self.actionBriefingOpen,
                        title: String(localized: "Open"),
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
            // v0.5.4.3 HP5 — MOOD_REMINDER category lands in lock-step
            // with server PR #190. "Stimmung erfassen" is foreground so
            // the tap opens the app onto the central-CTA quick-entry
            // sheet. "Snooze 1h" stays backgrounded (snooze is silent
            // re-schedule). "Heute überspringen" is destructive so iOS
            // renders it in red — semantic intent is "I will NOT log
            // mood today", matching the medication-skip pattern.
            let mood = UNNotificationCategory(
                identifier: Self.categoryMood,
                actions: [
                    UNNotificationAction(
                        identifier: Self.actionMoodLogNow,
                        title: String(localized: "Log mood"),
                        options: [.foreground]
                    ),
                    UNNotificationAction(
                        identifier: Self.actionMoodSnooze,
                        title: String(localized: "Snooze 1 h"),
                        options: []
                    ),
                    UNNotificationAction(
                        identifier: Self.actionMoodDismiss,
                        title: String(localized: "Skip today"),
                        options: [.destructive]
                    )
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            // W-B185 — low-supply heads-up: NO actions, so iOS shows only the
            // plain banner (body-tap deep-links to supply). Crucially carries
            // none of the Taken/Snooze/Skipped intake actions, which on a supply
            // alert would let a tap record a dose the user never took.
            let medicationLowStock = UNNotificationCategory(
                identifier: Self.categoryMedicationLowStock,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
            // W-B189 (#23) — preventive-care reminder. A single "Erledigt"/
            // complete action (foreground, so the tap opens the app onto the
            // measurement capture surface). The body-tap deep-links to capture
            // via the server-supplied `deepLink`. `.customDismissAction` so a
            // swipe-away is observable (parity with med/mood) even though the
            // dismiss is a client-only no-op today.
            let measurementReminder = UNNotificationCategory(
                identifier: Self.categoryMeasurementReminder,
                actions: [
                    UNNotificationAction(
                        identifier: Self.actionMeasurementDone,
                        title: String(localized: "measurement.reminder.action.done"),
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            // W-THRESHOLD-NUDGE — informational out-of-range nudge. NO actions
            // (it is retrospective + non-diagnostic — there is nothing to "do"
            // from the banner); a body-tap deep-links to the labs surface. The
            // `.passive`/`.active` interruption level is set on the content, so
            // the Focus filter can hold it back like any routine reminder.
            let thresholdNudge = UNNotificationCategory(
                identifier: Self.categoryThresholdNudge,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
            UNUserNotificationCenter.current()
                .setNotificationCategories(
                    [medication, medicationLowStock, briefing, mood, measurementReminder, thresholdNudge]
                )
        }
    }

#endif
