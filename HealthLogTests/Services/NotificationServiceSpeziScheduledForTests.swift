import Foundation
@testable import HealthLog
import Testing

/// SpeziScheduler builds its `UNNotificationRequest`s at reconcile time, and
/// the `SchedulerNotificationsConstraint` hook only sees the task + content —
/// never the trigger. So the `scheduledFor` stamped into the userInfo there is
/// the BUILD instant, not the fire instant. The action handler must therefore
/// resolve `scheduledFor` from the delivery date for Spezi-built banners, and
/// leave server-push payloads (which carry the real slot) untouched.
@MainActor
@Suite("NotificationService — Spezi-built banners resolve scheduledFor at delivery")
struct NotificationServiceSpeziScheduledForTests {
    private let built = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("speziScheduled payload → scheduledFor is the delivery date, not the build date")
    func speziPayloadResolvesToDeliveryDate() throws {
        let delivered = built.addingTimeInterval(13 * 3600)
        var info = NotificationService.medicationUserInfo(
            medicationId: "med_1", scheduleId: "sch_1", scheduledFor: built
        )
        info["speziScheduled"] = true
        let payload = try #require(NotificationService.resolvedPayload(userInfo: info, deliveredAt: delivered))
        #expect(payload.scheduledFor == delivered)
        #expect(payload.medicationId == "med_1")
    }

    @Test("server push payload keeps the scheduledFor it carries")
    func serverPayloadKeepsScheduledFor() throws {
        let delivered = built.addingTimeInterval(13 * 3600)
        let info = NotificationService.medicationUserInfo(
            medicationId: "med_1", scheduleId: "sch_1", scheduledFor: built
        )
        let payload = try #require(NotificationService.resolvedPayload(userInfo: info, deliveredAt: delivered))
        #expect(payload.scheduledFor == built)
    }
}
