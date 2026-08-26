import Foundation
@testable import HealthLog
import Testing
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// **v0.10.0 W-Mood-B** — pins the iOS-local evening mood reminder.
///
/// The reconcile orchestration (`reconcileMoodReminder`) talks to
/// `UNUserNotificationCenter` (auth-gated, flaky in the host-app-less runner),
/// so the load-bearing assertions ride the **pure** seams: the request builder
/// (`buildMoodReminderRequest`), the next-fire-instant computation, the
/// `notificationPrefs.mood.reminderHour` decode + clamp, and the
/// `MoodReminderPrefStore` mirror.
// swiftlint:disable force_unwrapping

@Suite("NotificationService — local mood reminder")
struct NotificationServiceMoodReminderTests {
    /// 2026-05-31 09:00 local, a fixed reference clock.
    private var morning: Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 5
        c.day = 31
        c.hour = 9
        c.minute = 0
        return Calendar.current.date(from: c)!
    }

    #if canImport(UserNotifications) && canImport(UIKit)
        @Test("buildMoodReminderRequest carries the MOOD_REMINDER category + routing userInfo")
        func requestCategoryAndUserInfo() {
            let req = NotificationService.buildMoodReminderRequest(hour: 22, now: morning)
            #expect(req.identifier == NotificationService.moodReminderLocalIdentifier)
            #expect(req.content.categoryIdentifier == NotificationService.categoryMood)
            #expect(req.content.userInfo["eventType"] as? String == NotificationService.categoryMood)
        }

        @Test("The reminder uses the .active interruption level (NOT time-sensitive)")
        func requestInterruptionLevelActive() {
            // M-3 — a wellness nudge must not borrow the meds-only
            // time-sensitive entitlement; it stays at the default `.active`.
            let req = NotificationService.buildMoodReminderRequest(hour: 22, now: morning)
            #expect(req.content.interruptionLevel == .active)
        }

        @Test("v0.14.1 H2 — the reminder is a REPEATING daily calendar trigger at the chosen hour")
        func requestIsRepeatingAtHour() throws {
            let req = NotificationService.buildMoodReminderRequest(hour: 20, now: morning)
            let trigger = try #require(req.trigger as? UNCalendarNotificationTrigger)
            // H2: repeats indefinitely so a backgrounded / force-quit app never
            // has to re-arm it — iOS re-fires it daily.
            #expect(trigger.repeats == true)
            #expect(trigger.dateComponents.hour == 20)
            #expect(trigger.dateComponents.minute == 0)
        }

        @Test("v0.14.1 H2 — the repeating trigger matches only hour+minute (no day/month), so it fires every day")
        func requestMatchesHourMinuteOnly() throws {
            // A repeating daily trigger must NOT pin a concrete day/month —
            // otherwise it would fire once and never repeat. iOS now owns the
            // "today vs tomorrow" roll, so `now` no longer changes the trigger.
            let atNine = NotificationService.buildMoodReminderRequest(hour: 8, now: morning)
            let trigger = try #require(atNine.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.repeats == true)
            #expect(trigger.dateComponents.day == nil)
            #expect(trigger.dateComponents.month == nil)
            #expect(trigger.dateComponents.year == nil)
            #expect(trigger.dateComponents.hour == 8)
            #expect(trigger.dateComponents.minute == 0)
        }

        @Test("The fire hour is clamped into 0…23")
        func hourClamped() throws {
            let high = NotificationService.buildMoodReminderRequest(hour: 99, now: morning)
            let trigger = try #require(high.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.dateComponents.hour == 23)
        }
    #endif

    // MARK: - Server pref decode + clamp

    @Test("moodReminderHour reads the server value when present")
    func prefsHourFromServer() {
        let payload = NotificationPreferencesPayload(
            channels: [], preferences: [], eventTypes: [],
            mood: MoodNotificationPrefs(reminderHour: 19)
        )
        #expect(payload.moodReminderHour == 19)
    }

    @Test("moodReminderHour falls back to 22 on a legacy server (no mood prefs)")
    func prefsHourDefault() {
        let payload = NotificationPreferencesPayload(
            channels: [], preferences: [], eventTypes: [], mood: nil
        )
        #expect(payload.moodReminderHour == NotificationPreferencesPayload.defaultMoodReminderHour)
        #expect(payload.moodReminderHour == 22)
    }

    @Test("moodReminderHour clamps an out-of-range server value")
    func prefsHourClamped() {
        let payload = NotificationPreferencesPayload(
            channels: [], preferences: [], eventTypes: [],
            mood: MoodNotificationPrefs(reminderHour: 99)
        )
        #expect(payload.moodReminderHour == 23)
    }

    @Test("A legacy preferences JSON without a mood key decodes with nil mood")
    func legacyPreferencesDecode() throws {
        let json = """
        {"channels":[],"preferences":[],"eventTypes":["MOOD_REMINDER"]}
        """
        let payload = try JSONDecoder().decode(
            NotificationPreferencesPayload.self, from: Data(json.utf8)
        )
        #expect(payload.mood == nil)
        #expect(payload.moodReminderHour == 22)
    }

    // MARK: - UserDefaults mirror

    @Test("MoodReminderPrefStore round-trips and defaults to 22")
    func prefStoreRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-mood-reminder-\(UUID().uuidString)"))
        // Never-written → default 22.
        #expect(MoodReminderPrefStore.hour(defaults: defaults) == 22)
        MoodReminderPrefStore.setHour(20, defaults: defaults)
        #expect(MoodReminderPrefStore.hour(defaults: defaults) == 20)
        // Clamped on write.
        MoodReminderPrefStore.setHour(99, defaults: defaults)
        #expect(MoodReminderPrefStore.hour(defaults: defaults) == 23)
    }
}

// swiftlint:enable force_unwrapping
