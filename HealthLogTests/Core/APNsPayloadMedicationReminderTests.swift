import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.3 F-4 — `APNsPayload` extensions for the medication-reminder
/// action contract. The server's `reminder-worker.ts` attaches
/// `medicationId`, `scheduleId`, and `scheduledFor` to the push so the
/// iOS action handler can call the bulk-intake endpoint without a
/// pre-existing intake-row. These tests pin the parser's shape so a
/// silent server-side payload-key rename surfaces immediately.
@Suite("APNsPayload — MEDICATION_REMINDER metadata")
struct APNsPayloadMedicationReminderTests {
    @Test("Parses medicationId + scheduleId + scheduledFor from top-level userInfo")
    func parsesReminderMetadata() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": ["title": "Lisinopril 5 mg", "body": "Zeit fuer deine Mittag-Dosis"],
                "category": "MEDICATION_REMINDER"
            ],
            "eventType": "MEDICATION_REMINDER",
            "medicationId": "med-abc-123",
            "scheduleId": "sched-xyz-789",
            "scheduledFor": "2026-05-17T12:00:00.000Z"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.medicationId == "med-abc-123")
        #expect(payload?.scheduleId == "sched-xyz-789")
        #expect(payload?.scheduledFor != nil)
        // 2026-05-17T12:00:00Z parsed back via the same ISO-8601 formatter
        // family yields the canonical Date. Comparing via the formatter
        // is more robust than a hand-computed epoch (timezone math is a
        // mid-2020s footgun).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-05-17T12:00:00.000Z")
        #expect(payload?.scheduledFor == expected)
    }

    @Test("scheduledFor without fractional seconds also parses")
    func parsesPlainISO8601() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"]],
            "eventType": "MEDICATION_REMINDER",
            "medicationId": "med-1",
            "scheduledFor": "2026-05-17T12:00:00Z"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.scheduledFor != nil)
    }

    @Test("Missing medication-reminder keys leaves all three optionals nil")
    func missingReminderMetadata() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Personal Record", "body": "Best ever"]],
            "eventType": "PERSONAL_RECORD"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.medicationId == nil)
        #expect(payload?.scheduleId == nil)
        #expect(payload?.scheduledFor == nil)
    }

    @Test("medicationId of wrong type (Int) is rejected → nil")
    func medicationIdWrongType() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T"]],
            "eventType": "MEDICATION_REMINDER",
            "medicationId": 12345
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.medicationId == nil)
    }

    @Test("scheduledFor malformed string → nil rather than crash")
    func scheduledForMalformed() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T"]],
            "eventType": "MEDICATION_REMINDER",
            "medicationId": "med-1",
            "scheduledFor": "not-a-date"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.scheduledFor == nil)
        // The rest of the payload still parses — silent malformed-date
        // must not poison the whole parse.
        #expect(payload?.medicationId == "med-1")
    }
}

// swiftlint:enable force_unwrapping
