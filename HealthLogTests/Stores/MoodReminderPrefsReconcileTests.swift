import Foundation
@testable import HealthLog
import Testing

/// The evening mood reminder is a repeating iOS-local trigger. Until now the
/// toggle (`SettingsStore.updateMoodReminderEnabled`) and the hour
/// (`NotificationsStore.setMoodReminderHour`) only wrote prefs; the local
/// request was re-armed on the NEXT foreground pass. Turning the reminder off
/// at 21:50 and locking the phone still delivered the 22:00 banner. Both
/// stores must announce the change so the composition root can reconcile
/// immediately.
@MainActor
@Suite("Mood reminder prefs → immediate reconcile seam")
struct MoodReminderPrefsReconcileTests {
    private nonisolated static func profile(moodReminderEnabled: Bool) -> UserProfile {
        UserProfile(
            username: "anna",
            displayName: "Anna",
            email: "anna@example.com",
            dateOfBirth: nil,
            gender: nil,
            heightCm: 175,
            locale: "de",
            timezone: "Europe/Berlin",
            moodReminderEnabled: moodReminderEnabled
        )
    }

    @Test("toggling the reminder off announces enabled=false after the successful PATCH")
    func toggleOffAnnounces() async throws {
        let api = StubAPIClient()
        await api.setHandler { _ in Self.profile(moodReminderEnabled: false) }
        let suiteName = "MoodReminderPrefsReconcileTests.\(UUID().uuidString)"
        let store = try SettingsStore(
            repo: SettingsRepository(api: api),
            defaults: #require(UserDefaults(suiteName: suiteName))
        )
        var announced: [Bool] = []
        store.onMoodReminderEnabledChanged = { announced.append($0) }

        let ok = await store.updateMoodReminderEnabled(false)
        #expect(ok == true)
        #expect(announced == [false])
    }

    @Test("changing the hour announces the new hour")
    func hourChangeAnnounces() async {
        let api = StubAPIClient()
        await api.setHandler { _ in
            AuthNotificationPrefsPayload(mood: .init(reminderHour: 20))
        }
        let store = NotificationsStore(repo: NotificationsRepository(api: api))
        var announced: [Int] = []
        store.onMoodReminderHourChanged = { announced.append($0) }

        await store.setMoodReminderHour(20)
        #expect(announced == [20])
        #expect(store.error == nil)
    }
}
