import Foundation
@testable import HealthLog
import Testing

/// Verifies the UX-priority sort order on the Notifications-Settings screen.
/// Drives the section ordering reported by the user as confusing in v0.3.
@Suite("NotificationEventPriority ordering")
struct NotificationEventPriorityTests {
    @Test("DAILY_BRIEFING ranks above MEDICATION_REMINDER")
    func dailyBriefingFirst() {
        let a = NotificationEventPriority.rank(of: "DAILY_BRIEFING")
        let b = NotificationEventPriority.rank(of: "MEDICATION_REMINDER")
        #expect(a < b)
    }

    @Test("MEDICATION_REMINDER ranks above SYSTEM_ALERT")
    func medsBeforeSystem() {
        let a = NotificationEventPriority.rank(of: "MEDICATION_REMINDER")
        let b = NotificationEventPriority.rank(of: "SYSTEM_ALERT")
        #expect(a < b)
    }

    @Test("Unknown event types fall to the end")
    func unknownAtEnd() {
        let a = NotificationEventPriority.rank(of: "SYSTEM_ALERT")
        let b = NotificationEventPriority.rank(of: "NEWLY_INVENTED_EVENT")
        #expect(a < b)
    }

    @Test("Sorting a mixed list yields the expected order")
    func mixedSort() {
        let mixed = [
            "SYSTEM_ALERT",
            "DAILY_BRIEFING",
            "MEDICATION_REMINDER",
            "ACHIEVEMENT_UNLOCKED",
            "MEASUREMENT_ANOMALY",
            "INSIGHT_READY"
        ]
        let sorted = mixed.sorted { lhs, rhs in
            NotificationEventPriority.rank(of: lhs)
                < NotificationEventPriority.rank(of: rhs)
        }
        #expect(sorted == [
            "DAILY_BRIEFING",
            "MEDICATION_REMINDER",
            "ACHIEVEMENT_UNLOCKED",
            "INSIGHT_READY",
            "MEASUREMENT_ANOMALY",
            "SYSTEM_ALERT"
        ])
    }

    @Test("Localization helper produces non-empty title for every priority key")
    func localizationCoverage() {
        let keys = [
            "DAILY_BRIEFING", "STREAK_REMINDER", "MEDICATION_REMINDER",
            "ACHIEVEMENT_UNLOCKED", "PERSONAL_RECORD", "INSIGHT_READY",
            "MEASUREMENT_ANOMALY", "COMPLIANCE_LOW", "WITHINGS_SYNC_FAILED",
            "SYSTEM_ALERT"
        ]
        for k in keys {
            let title = NotificationEventLocalization.title(for: k)
            #expect(!title.isEmpty, "missing title for \(k)")
        }
    }
}
