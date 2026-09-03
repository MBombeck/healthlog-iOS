import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// v0.5.4.3 HP5 — `MOOD_REMINDER` action handlers split out from
    /// `NotificationService.swift` to keep the parent file under the
    /// 600-LOC SwiftLint warning ceiling.
    ///
    /// Three actions wire into `NotificationService.dispatchAction`:
    /// - `mood.log.now`   → route to the central-CTA `MoodQuickEntrySheet`
    ///                      via `DeepLinkRouter.routeToMoodQuickEntry()`.
    /// - `mood.snooze.1h` → schedule a local `UNTimeIntervalNotificationTrigger`
    ///                      one hour out, same `MOOD_REMINDER` category +
    ///                      copied metadata so the snoozed banner re-renders
    ///                      the 3 actions identically.
    /// - `mood.dismiss`   → client-only no-op (logged). Server has no
    ///                      dismiss endpoint by design — the cron's per-
    ///                      day idempotency ledger already throttles to a
    ///                      single push per local day, and the next day's
    ///                      22:00 tick is the right moment to nudge again.
    ///
    /// Symmetry with the medication-snooze pattern is deliberate: same
    /// shape of metadata-carry-through, same `categoryIdentifier` re-set
    /// so iOS keeps rendering the 3-action chrome on the re-fire.
    extension NotificationService {
        /// `mood.log.now` — present the central-CTA `MoodQuickEntrySheet`.
        /// The action has `.foreground` so iOS opens the app before the
        /// handler fires; we just signal the router to flip to home +
        /// surface the sheet. No server roundtrip — the mood entry is
        /// written when the user actually saves inside the sheet.
        @MainActor
        func handleMoodLogNow() async {
            HLLog.notifications.info("mood.log.now — routing to MoodQuickEntrySheet")
            deepLinks.routeToMoodQuickEntry()
        }

        /// `mood.snooze.1h` — local re-schedule. Mirrors the medication-
        /// snooze pattern: same metadata copied through `userInfo`, same
        /// `MOOD_REMINDER` category so the snoozed banner re-renders the
        /// 3 actions. Server has no "snoozed mood reminder" concept; the
        /// next day's 22:00 cron tick fires normally regardless of any
        /// in-flight local snooze.
        @MainActor
        func handleMoodSnooze(payload: APNsPayload?) async {
            let req = Self.buildMoodSnoozeRequest(payload: payload)
            do {
                // Build 273 — through the shared gate (Focus filter + pending
                // budget), like the original evening nudge.
                try await addLocalNotification(req)
                // Locally generated random snooze id ("mood-snooze-<UUID>"); the UUID
                // portion is sanitizer-redacted by HLLogger anyway — no user data.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.info("mood.snooze.1h: re-scheduled id=\(req.identifier, privacy: .public)")
            } catch {
                HLLog.notifications.error(
                    "mood.snooze.1h: scheduling failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// Pure builder for the snooze request — exposed at internal
        /// scope so tests can assert on the produced content + trigger
        /// shape without depending on `UNUserNotificationCenter.\
        /// pendingNotificationRequests` (which is flaky in the host-
        /// app-less test runner because the simulator may not have
        /// authorization granted).
        static func buildMoodSnoozeRequest(payload: APNsPayload?) -> UNNotificationRequest {
            let id = "mood-snooze-\(UUID().uuidString)"
            let content = UNMutableNotificationContent()
            content.title = payload?.title ?? String(localized: "How are you feeling right now?")
            content.body = payload?.body ?? String(localized: "Log your mood quickly.")
            content.sound = .default
            content.categoryIdentifier = Self.categoryMood
            // Build 273 — the evening mood nudge is a ROUTINE `.active`
            // reminder by design (App-Review rationale in `+MoodReminder`);
            // a snooze must not escalate it past the level the original
            // respected, or it breaks through a Focus the original did not.
            content.interruptionLevel = .active
            var userInfo: [String: Any] = [:]
            if let eventType = payload?.eventType {
                userInfo["eventType"] = eventType
            } else {
                // Snooze without a server-side eventType still needs the
                // marker so the default-action branch can route by event-
                // type lookup when the user later taps the body.
                userInfo["eventType"] = Self.categoryMood
            }
            content.userInfo = userInfo
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Self.moodSnoozeIntervalSeconds,
                repeats: false
            )
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        /// `mood.dismiss` — client-only "skip today" action. Server has
        /// no dismiss endpoint (intentional — the cron's idempotency
        /// ledger naturally throttles to one push per local day, and the
        /// next day's tick is the right moment to nudge again). We log
        /// the dismissal for observability and exit; no inbox row is
        /// removed because the original push already mirrored into the
        /// inbox at delivery time and the user may still want the audit
        /// trail.
        @MainActor
        func handleMoodDismiss(payload: APNsPayload?) async {
            _ = payload
            HLLog.notifications.info("mood.dismiss — user opted out of today's mood reminder (client-only)")
        }
    }

#endif
