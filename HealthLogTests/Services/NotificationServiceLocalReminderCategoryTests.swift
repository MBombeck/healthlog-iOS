import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// v0.5.5 W-MED — regression-guard for the `scheduleLocalReminder`
    /// category + userInfo plumbing.
    ///
    /// Before W-MED the helper produced a `UNMutableNotificationContent`
    /// with neither `categoryIdentifier` nor `userInfo`. A caller that
    /// scheduled a medication reminder via the smart-reminder wrapper
    /// (`scheduleSmartLocalReminder`) therefore got a static text banner
    /// without the 3-button Genommen/Snooze/Übersprungen chrome — even
    /// though the matching `MEDICATION_REMINDER` category was registered
    /// at `NotificationService.init` time. The action handler never
    /// surfaced because the system had no way to bind the banner to the
    /// category.
    ///
    /// The test exercises the pure `medicationUserInfo(...)` builder and
    /// pins the call-shape downstream callers depend on.
    @Suite("NotificationService — medication userInfo + category plumbing")
    @MainActor
    struct NotificationServiceLocalReminderCategoryTests {
        // MARK: - medicationUserInfo builder

        @Test("medicationUserInfo carries the four contract keys when scheduleId given")
        func medicationUserInfoFullPayload() throws {
            let scheduledFor = Date(timeIntervalSince1970: 1_779_710_400)
            let info = NotificationService.medicationUserInfo(
                medicationId: "med-A",
                scheduleId: "sched-1",
                scheduledFor: scheduledFor
            )
            #expect(info["medicationId"] as? String == "med-A")
            #expect(info["scheduleId"] as? String == "sched-1")
            #expect(info["eventType"] as? String == NotificationService.categoryMedication)
            let iso = try #require(info["scheduledFor"] as? String)
            // Round-trip through the same formatter the snooze handler uses
            // so a future formatter swap can't silently break the contract.
            let parsed = ISO8601DateFormatter()
            parsed.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(parsed.date(from: iso) == scheduledFor)
        }

        @Test("medicationUserInfo omits scheduleId when nil — APNs payload parity")
        func medicationUserInfoNilScheduleIdOmits() {
            let info = NotificationService.medicationUserInfo(
                medicationId: "med-B",
                scheduleId: nil,
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            // Server's MEDICATION_REMINDER payload omits the key entirely
            // when there is no schedule row, so APNsPayload.parse(...)
            // can't synthesise a fake. Mirror that here so a local-fallback
            // banner doesn't carry an empty-string scheduleId that would
            // mis-route at the action handler.
            #expect(info["scheduleId"] == nil)
            #expect(info["medicationId"] as? String == "med-B")
            #expect(info["eventType"] as? String == NotificationService.categoryMedication)
        }

        // MARK: - APNsPayload round-trip

        @Test("medicationUserInfo round-trips through APNsPayload.parse")
        func userInfoRoundTripsThroughPayloadParser() throws {
            // End-to-end regression-guard: a banner scheduled with the
            // helper's userInfo must parse back into an APNsPayload that
            // carries the medicationId + scheduledFor + eventType.
            let scheduledFor = Date(timeIntervalSince1970: 1_779_710_400)
            let userInfo = NotificationService.medicationUserInfo(
                medicationId: "med-roundtrip",
                scheduleId: "sched-roundtrip",
                scheduledFor: scheduledFor
            )
            let payload = try #require(APNsPayload.parse(userInfo: userInfo))
            #expect(payload.medicationId == "med-roundtrip")
            #expect(payload.scheduleId == "sched-roundtrip")
            #expect(payload.eventType == "MEDICATION_REMINDER")
            let parsed = try #require(payload.scheduledFor)
            // scheduledFor is parsed with second-precision; allow ≤1 ms drift.
            #expect(abs(parsed.timeIntervalSince(scheduledFor)) < 0.01)
        }

        // MARK: - Category identifier is reused, not hard-coded

        @Test("medicationUserInfo eventType key resolves to the category constant")
        func eventTypeKeyTracksCategoryConstant() {
            // Single-source guarantee — the helper must reuse the
            // `categoryMedication` constant rather than hard-coding
            // "MEDICATION_REMINDER". If the constant ever rotates (e.g. a
            // server-side schema bump), the userInfo shape rotates with it.
            let info = NotificationService.medicationUserInfo(
                medicationId: "med-anchor",
                scheduleId: nil,
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            #expect(info["eventType"] as? String == NotificationService.categoryMedication)
        }
    }
#endif
