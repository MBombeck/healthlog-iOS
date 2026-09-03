@testable import HealthLog
import Testing

/// `reconcileMoodReminder` used to remove the pending repeating request and
/// then hand the rebuilt one to the Focus-gated `addLocalNotification`, which
/// refuses to add while a HealthLog Focus filter suppresses routine reminders.
/// Net effect: one reconcile during a Focus (any foreground, any mood entry,
/// the nightly BGTask) deleted the reminder for every future day. The decision
/// is now explicit: under Focus the existing request is left in place.
@Suite("NotificationService — mood reminder reconcile decision")
struct NotificationServiceMoodReconcileDecisionTests {
    @Test("Focus suppression keeps the pending request instead of deleting it")
    func focusSuppressedKeepsPending() {
        #expect(
            NotificationService.moodReminderReconcileDecision(enabled: true, authorized: true, focusSuppressed: true)
                == .keepPending
        )
    }

    @Test("no Focus → re-arm (replace in place)")
    func rearm() {
        #expect(
            NotificationService.moodReminderReconcileDecision(enabled: true, authorized: true, focusSuppressed: false)
                == .rearm
        )
    }

    @Test("disabled → cancel, regardless of Focus")
    func disabledCancels() {
        #expect(
            NotificationService.moodReminderReconcileDecision(enabled: false, authorized: true, focusSuppressed: true)
                == .cancel
        )
    }

    @Test("not authorized → cancel, regardless of Focus")
    func unauthorizedCancels() {
        #expect(
            NotificationService.moodReminderReconcileDecision(enabled: true, authorized: false, focusSuppressed: true)
                == .cancel
        )
    }
}
