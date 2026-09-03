import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// **v0.10.0 W-Mood-B** — UserDefaults mirror of the server's
/// `notificationPrefs.mood.reminderHour`.
///
/// The server (v1.7.0) is the source of truth, but the local scheduler runs on
/// every foreground — sometimes before the notification-prefs payload has
/// loaded (or while offline / standalone). This mirror lets the scheduler read
/// a sensible hour immediately: the Settings card + the prefs-load path write
/// it whenever the server value is known; the scheduler reads it with a 22:00
/// fallback. UserDefaults is the correct tier — it's a UI-pref echo, not the
/// authority.
public enum MoodReminderPrefStore {
    private static let hourKey = "hl.mood.reminderHour"
    public static let defaultHour = 22

    /// The mirrored hour (0–23), defaulting to 22 when never written.
    public static func hour(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: hourKey) != nil else { return defaultHour }
        return max(0, min(23, defaults.integer(forKey: hourKey)))
    }

    /// Mirror the (server-authoritative) hour locally. Clamped to 0–23.
    public static func setHour(_ hour: Int, defaults: UserDefaults = .standard) {
        defaults.set(max(0, min(23, hour)), forKey: hourKey)
    }
}

/// **MED-4 / AUDIT-PARITY C3** — UserDefaults mirror of the server's
/// `notificationPrefs.medication.lowStockRunwayDays` low-supply threshold.
///
/// The server cron is the authority for *firing* the alert, but the medication
/// card / detail screen needs the threshold to decide when to render the runway
/// ("≈ X Tage") — and that screen is reachable before the Notifications-prefs
/// payload has loaded (or while offline / standalone). This mirror lets any
/// medication surface read the threshold immediately: the Settings card + the
/// prefs cold-read write it whenever the server value is known; medication
/// screens read it. `nil` (no key written, OR an explicit off) means the alert
/// is off and nothing renders. UserDefaults is the correct tier — a UI-pref
/// echo of a server-known value, not the authority.
public enum LowStockRunwayPrefStore {
    private static let daysKey = "hl.medication.lowStockRunwayDays"
    /// Sentinel written when the user turns the alert OFF, distinguishing
    /// "explicitly off" from "never set" (no key) — both read back as `nil`,
    /// but the sentinel lets a future read avoid re-defaulting to 7.
    private static let offSentinel = -1

    /// The mirrored threshold (1–60), or `nil` when off / never written.
    public static func days(defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: daysKey) != nil else { return nil }
        let raw = defaults.integer(forKey: daysKey)
        guard raw >= medicationLowStockRunwayMin else { return nil }
        return max(medicationLowStockRunwayMin, min(medicationLowStockRunwayMax, raw))
    }

    /// Mirror the (server-authoritative) threshold locally. `nil` clears the
    /// alert (writes the off-sentinel so the read returns `nil`).
    public static func setDays(_ days: Int?, defaults: UserDefaults = .standard) {
        if let days {
            defaults.set(max(medicationLowStockRunwayMin, min(medicationLowStockRunwayMax, days)), forKey: daysKey)
        } else {
            defaults.set(offSentinel, forKey: daysKey)
        }
    }
}

#if canImport(UserNotifications)

    /// **v0.10.0 W-Mood-B — iOS-local evening mood reminder.**
    ///
    /// The server APNs cron path (v1.7.0) is a backstop; this local scheduler
    /// is the load-bearing reliability fix (R-Mood-5). It arms a **repeating**
    /// daily `UNCalendarNotificationTrigger(repeats: true)` at the user's chosen
    /// hour (server `notificationPrefs.mood.reminderHour`, default 22).
    ///
    /// **v0.14.1 notifications-bug H2 — repeating, not re-armed.** Previously
    /// this was a one-shot `repeats: false` trigger the app had to re-arm on
    /// every foreground / day-rollover, and it cancelled itself when a mood
    /// entry already existed for today. That re-arm is exactly the background
    /// failure the operator hit: a backgrounded / force-quit app never re-arms,
    /// so after the single queued nudge fired the reminder went silent. It is
    /// now a single OS-delivered repeating trigger that iOS fires every day with
    /// zero app involvement. The "already logged today → don't nag" gate moved
    /// to the foreground delegate (`userNotificationCenter(_:willPresent:)`
    /// suppresses the banner when a mood entry exists for today). The tradeoff:
    /// when the app is backgrounded at fire-time the nudge is delivered even if
    /// mood was already logged — a rare, harmless double-nudge (never a missed
    /// reminder), and the wellness nudge is not safety-relevant like a med dose.
    ///
    /// Tap + actions already route correctly (`dispatchAction` →
    /// `routeToMoodQuickEntry`), so the receive side is free — we reuse the
    /// existing `MOOD_REMINDER` category + its three actions.
    extension NotificationService {
        /// Stable identifier so re-arming replaces (rather than stacks) the
        /// pending request, and so the disable path has a fixed key to remove.
        nonisolated static let moodReminderLocalIdentifier = "mood-reminder-local"

        /// Reconcile the local mood reminder against the current state. Call on
        /// app foreground and after a toggle / hour change.
        ///
        /// - `enabled`: the user's `moodReminderEnabled` intent (reuses the
        ///   existing toggle).
        /// - `hour`: the local-clock hour (0–23) to fire at.
        ///
        /// When disabled or auth-denied → the pending reminder is cancelled.
        /// Otherwise a **repeating** daily reminder is (re-)armed at the chosen
        /// hour — a single OS-delivered trigger with no background re-arm
        /// dependency (H2). Idempotent: re-running replaces the same-id request
        /// so a changed hour re-arms cleanly. Never throws — a scheduling hiccup
        /// must not break the foreground path.
        @MainActor
        func reconcileMoodReminder(
            enabled: Bool,
            hour: Int,
            now: Date = .now,
            calendar: Calendar = .current
        ) async {
            let center = UNUserNotificationCenter.current()

            // Gate 1 — opted out → cancel + done.
            guard enabled else {
                center.removePendingNotificationRequests(
                    withIdentifiers: [Self.moodReminderLocalIdentifier]
                )
                return
            }

            // Gate 2 — respect notification authorization. If the user hasn't
            // granted notifications, don't try to schedule (it would silently
            // drop) — the existing connect-banner surfaces the permission ask.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else
            {
                center.removePendingNotificationRequests(
                    withIdentifiers: [Self.moodReminderLocalIdentifier]
                )
                return
            }

            let request = Self.buildMoodReminderRequest(
                hour: hour,
                now: now,
                calendar: calendar
            )
            // Build 272 — a HealthLog Focus filter must HOLD the routine nudge
            // back, not delete it. Removing the pending request and then handing
            // the rebuilt one to the Focus-gated `addLocalNotification` (which
            // refuses to add under Focus) deleted the repeating trigger for every
            // future day on any reconcile that ran during a Focus. Under Focus we
            // leave whatever is pending untouched; the next reconcile outside
            // the Focus applies the hour.
            let focusSuppressed = FocusFilterSuppression.shouldSuppress(request: request)
            switch Self.moodReminderReconcileDecision(
                enabled: true, authorized: true, focusSuppressed: focusSuppressed
            ) {
            case .cancel:
                center.removePendingNotificationRequests(
                    withIdentifiers: [Self.moodReminderLocalIdentifier]
                )
                return
            case .keepPending:
                HLLog.notifications.info("mood-reminder-local left as pending under Focus filter")
                return
            case .rearm:
                break
            }
            do {
                // Replace any existing pending request (same id) so a changed
                // hour re-arms cleanly.
                center.removePendingNotificationRequests(
                    withIdentifiers: [Self.moodReminderLocalIdentifier]
                )
                try await addLocalNotification(request, center: center)
                // Reminder hour (Int) — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.info(
                    "mood-reminder-local armed (repeating) for hour=\(hour, privacy: .public)"
                )
            } catch {
                HLLog.notifications.error(
                    "mood-reminder-local scheduling failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// What `reconcileMoodReminder` does with the pending repeating request.
        enum MoodReminderReconcileDecision: Equatable {
            /// Remove the pending request (opted out or not authorized).
            case cancel
            /// Leave the pending request exactly as it is (Focus filter active).
            case keepPending
            /// Replace the pending request with a freshly built one.
            case rearm
        }

        /// Pure decision behind `reconcileMoodReminder`: disabled or unauthorized
        /// always cancels; an active Focus filter keeps whatever is pending;
        /// otherwise re-arm in place.
        nonisolated static func moodReminderReconcileDecision(
            enabled: Bool,
            authorized: Bool,
            focusSuppressed: Bool
        ) -> MoodReminderReconcileDecision {
            guard enabled, authorized else { return .cancel }
            return focusSuppressed ? .keepPending : .rearm
        }

        /// Pure builder for the local mood-reminder request — exposed at
        /// internal scope so tests can pin the trigger contract (fire hour,
        /// repeating, the `MOOD_REMINDER` category + the routing userInfo)
        /// without `UNUserNotificationCenter` authorization.
        ///
        /// **v0.14.1 H2 — repeating daily trigger.** A bare `hour:minute`
        /// `UNCalendarNotificationTrigger(repeats: true)` fires at the next
        /// matching wall-clock time and then every day thereafter, delivered by
        /// iOS with no app involvement. The `now` / `calendar` parameters are
        /// retained for signature stability (and so a test can pin the hour
        /// clamp) but no longer resolve a concrete one-off fire date.
        nonisolated static func buildMoodReminderRequest(
            hour: Int,
            now _: Date = .now,
            calendar: Calendar = .current
        ) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "How are you feeling?")
            content.body = String(localized: "Take a moment to log your mood for today.")
            content.sound = .default
            // v0.10.0 W10 M-3 — a daily wellness nudge is NOT urgent: keep it
            // at `.active` (the default) and explicitly so. The app holds the
            // time-sensitive entitlement for *medication* reminders only;
            // marking a mood reminder `.timeSensitive`/`.critical` is an
            // App-Review "appropriate interruption level" concern. Setting it
            // explicitly documents the intent and survives any future default
            // change.
            content.interruptionLevel = .active
            content.categoryIdentifier = Self.categoryMood
            // The receive side keys on the eventType marker to route a body-tap
            // to the mood quick-entry sheet (see `dispatchAction`).
            content.userInfo = ["eventType": Self.categoryMood]

            let clampedHour = max(0, min(23, hour))
            // A repeating calendar trigger matches only the components we set —
            // hour + minute — so iOS re-fires it daily at that wall-clock time.
            // Stamp the timezone so the fire time tracks the user's local clock
            // (mirroring the medication-reminder TZ handling).
            var matched = DateComponents()
            matched.hour = clampedHour
            matched.minute = 0
            matched.timeZone = calendar.timeZone

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: matched,
                repeats: true
            )
            return UNNotificationRequest(
                identifier: Self.moodReminderLocalIdentifier,
                content: content,
                trigger: trigger
            )
        }
    }

#endif
