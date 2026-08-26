import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// v0.5.5 NOTIF-FIX — regression-guard for the `scheduleLocalReminder`
    /// trigger contract.
    ///
    /// **Bug:** `scheduleLocalReminder(...)` previously built a
    /// `UNCalendarNotificationTrigger` matched on
    /// `[.year, .month, .day, .hour, .minute]` with `repeats: false`. iOS
    /// fires such a trigger only at the FIRST instant the components
    /// match — if the target minute had already begun (e.g. scheduling at
    /// 12:42:30 for 12:42:45), the trigger could not fire that minute
    /// and `repeats: false` precluded later occurrences. Net effect:
    /// the banner silently never arrived. The operator's "even the local
    /// reminders I trigger don't arrive" reproduces this exact case
    /// because the smart-reminder + local-fallback paths schedule for
    /// "right now plus a few seconds".
    ///
    /// **Fix:** when the target lies within the next ~5 minutes,
    /// `scheduleLocalReminder` now emits a `UNTimeIntervalNotification\
    /// Trigger` clamped to `max(1, interval)`. Far-future schedules keep
    /// the calendar trigger but include `.second` so the matching window
    /// is unambiguous.
    ///
    /// These tests pin the trigger type by exercising the pure
    /// `buildLocalReminderRequest(...)` factory the wrapper delegates
    /// to — so they run without needing `UNUserNotificationCenter`
    /// authorization (the test runner can't grant it, and `add(...)`
    /// silently drops the request when unauthorized, which masks the
    /// trigger shape).
    @Suite("NotificationService — scheduleLocalReminder trigger fix (NOTIF-FIX)")
    @MainActor
    struct NotificationServiceTriggerFixTests {
        // MARK: - Near-future schedule uses time-interval trigger

        @Test("Near-future date (≤5 min out) produces a UNTimeIntervalNotificationTrigger")
        func nearFutureUsesTimeIntervalTrigger() throws {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(30)
            let req = NotificationService.buildLocalReminderRequest(
                id: "near",
                title: "Test",
                body: "Body",
                at: target,
                now: now
            )
            let trigger = try #require(req.trigger as? UNTimeIntervalNotificationTrigger)
            #expect(trigger.timeInterval == 30)
            #expect(trigger.repeats == false)
        }

        @Test("Same-second schedule clamps to a 1 s time-interval trigger")
        func sameSecondClampsToOneSecond() throws {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(0.1)
            let req = NotificationService.buildLocalReminderRequest(
                id: "now",
                title: "Test",
                body: "Body",
                at: target,
                now: now
            )
            let trigger = try #require(req.trigger as? UNTimeIntervalNotificationTrigger)
            #expect(trigger.timeInterval >= 1)
            #expect(trigger.repeats == false)
        }

        @Test("Past-date schedule falls into the calendar branch (defensive)")
        func pastDateFallsIntoCalendarBranch() throws {
            // A target stamp in the past has `interval <= 0` so the
            // near-future branch is skipped. We don't pretend such a
            // request will ever fire — but we want a defined trigger
            // type rather than a force-cast crash, so the calendar
            // branch handles it.
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(-60)
            let req = NotificationService.buildLocalReminderRequest(
                id: "past",
                title: "Test",
                body: "Body",
                at: target,
                now: now
            )
            let trigger = try #require(req.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.repeats == false)
        }

        // MARK: - Far-future schedule uses calendar trigger with second precision

        @Test("Far-future date (>5 min out) produces a UNCalendarNotificationTrigger with second granularity")
        func farFutureUsesCalendarTriggerWithSeconds() throws {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(60 * 60) // 1 hour out
            let req = NotificationService.buildLocalReminderRequest(
                id: "far",
                title: "Test",
                body: "Body",
                at: target,
                now: now
            )
            let trigger = try #require(req.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.repeats == false)
            // The matching components MUST include `.second` so the
            // trigger window is unambiguous. Pre-NOTIF-FIX the helper
            // used minute precision which races with the current-minute
            // boundary.
            let comps = trigger.dateComponents
            #expect(comps.second != nil)
            #expect(comps.minute != nil)
            #expect(comps.hour != nil)
            #expect(comps.day != nil)
            #expect(comps.year != nil)
        }

        // MARK: - Category + userInfo still preserved (W-MED carry-over)

        @Test("Trigger fix preserves category + userInfo plumbing (W-MED carry-over)")
        func preservesCategoryAndUserInfo() throws {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let userInfo = NotificationService.medicationUserInfo(
                medicationId: "med-1",
                scheduleId: "sched-1",
                scheduledFor: now.addingTimeInterval(30)
            )
            let req = NotificationService.buildLocalReminderRequest(
                id: "meta",
                title: "Med",
                body: "Take",
                at: now.addingTimeInterval(30),
                category: NotificationService.categoryMedication,
                userInfo: userInfo,
                now: now
            )
            #expect(req.content.categoryIdentifier == NotificationService.categoryMedication)
            #expect(req.content.userInfo["medicationId"] as? String == "med-1")
            #expect(req.content.userInfo["scheduleId"] as? String == "sched-1")
            // And the trigger MUST still be the time-interval flavour —
            // category plumbing must not regress the trigger fix.
            _ = try #require(req.trigger as? UNTimeIntervalNotificationTrigger)
        }

        // MARK: - Default args mean no category / no userInfo

        @Test("Default call (no category / userInfo) yields no categoryIdentifier and empty userInfo")
        func defaultArgsLeaveMetadataEmpty() {
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let req = NotificationService.buildLocalReminderRequest(
                id: "plain",
                title: "Test",
                body: "Body",
                at: now.addingTimeInterval(30),
                now: now
            )
            #expect(req.content.categoryIdentifier.isEmpty)
            #expect(req.content.userInfo.isEmpty)
            #expect(req.content.title == "Test")
            #expect(req.content.body == "Body")
        }
    }
#endif
