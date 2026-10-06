import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// **R1 — the local snooze holds one slot, like the server's (1.39.3, A5).**
    ///
    /// Server rule: a medication snooze holds only the slot whose reminder
    /// window was open when it was set; later slots of the same medication are
    /// still reminded. The app never writes a server snooze — "Snooze 15 min" on
    /// a reminder re-shows THAT reminder 15 minutes later — so it can only agree
    /// with the rule if the re-shown banner names the snoozed slot and leaves
    /// every other reminder alone. Both were already true on 1.1.0 (286); this
    /// pins them so a later change cannot turn the snooze medication-wide.
    @Suite("R1 — a medication snooze holds only the slot it was set on")
    @MainActor
    struct MedicationSnoozeSlotTests {
        static let morning = Date(timeIntervalSince1970: 1_790_838_000)

        static func payload(scheduledFor: Date) -> APNsPayload {
            APNsPayload(
                title: "Lisinopril",
                body: "5 mg",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: "med-1",
                scheduleId: "sched-1",
                scheduledFor: scheduledFor
            )
        }

        @Test("the snoozed banner names the snoozed slot, so Taken/Skip act on that dose only")
        func snoozeCarriesItsSlot() {
            let request = NotificationService.buildMedicationSnoozeRequest(payload: Self.payload(scheduledFor: Self.morning))
            #expect(request.content.userInfo["scheduledFor"] as? String == NotificationService.iso8601String(from: Self.morning))
            #expect(request.content.userInfo["medicationId"] as? String == "med-1")
        }

        @Test("each snooze is its own request: it replaces no other reminder of the medication")
        func snoozeReplacesNothing() {
            let evening = Self.morning.addingTimeInterval(12 * 3600)
            let first = NotificationService.buildMedicationSnoozeRequest(payload: Self.payload(scheduledFor: Self.morning))
            let second = NotificationService.buildMedicationSnoozeRequest(payload: Self.payload(scheduledFor: evening))
            #expect(first.identifier != second.identifier)
            #expect(first.identifier.hasPrefix("snooze-med-1-"))
        }
    }
#endif
