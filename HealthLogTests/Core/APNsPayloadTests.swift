import Foundation
@testable import HealthLog
import Testing

/// APNs-Payload-Parser. \`eventType\` bleibt opaque-string — alle 6
/// Server-bekannten Werte (06 § Domain 3) werden parsed, aber der Parser
/// erzwingt KEINEN closed-enum.
@Suite("APNsPayload parsing")
struct APNsPayloadTests {
    @Test("Leeres userInfo → nil")
    func emptyReturnsNil() {
        #expect(APNsPayload.parse(userInfo: [:]) == nil)
    }

    @Test("Vollstaendige Payload mit allen Feldern")
    func fullPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": ["title": "Personal Record", "body": "New all-time best: 8,420 steps"],
                "badge": 1,
                "sound": "default",
                "thread-id": "personal_record"
            ],
            "eventType": "PERSONAL_RECORD",
            "metricType": "ACTIVITY_STEPS",
            "value": 8420,
            "deepLink": "healthlog://personal-records/cmp-2026-05-13-steps"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.title == "Personal Record")
        #expect(payload?.body == "New all-time best: 8,420 steps")
        #expect(payload?.eventType == "PERSONAL_RECORD")
        #expect(payload?.metricType == "ACTIVITY_STEPS")
        #expect(payload?.deepLink?.absoluteString == "healthlog://personal-records/cmp-2026-05-13-steps")
        #expect(payload?.isContentAvailable == false)
    }

    @Test("Alle 6 Server-Event-Types parsen")
    func allKnownEventTypes() {
        let types = [
            "MEDICATION_REMINDER",
            "MEASUREMENT_ANOMALY",
            "COMPLIANCE_LOW",
            "WITHINGS_SYNC_FAILED",
            "SYSTEM_ALERT",
            "PERSONAL_RECORD"
        ]
        for type in types {
            let userInfo: [AnyHashable: Any] = [
                "aps": ["alert": ["title": "T", "body": "B"]],
                "eventType": type
            ]
            let payload = APNsPayload.parse(userInfo: userInfo)
            #expect(payload?.eventType == type, "Failed for \(type)")
        }
    }

    @Test("Fehlender deepLink → nil")
    func missingDeepLink() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"]],
            "eventType": "MEDICATION_REMINDER"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.deepLink == nil)
    }

    @Test("deepLink kein String → nil")
    func deepLinkWrongType() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T"]],
            "eventType": "MEDICATION_REMINDER",
            "deepLink": 12345
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.deepLink == nil)
    }

    @Test("Alert als reiner String (Apple-legacy) → body fields")
    func alertAsString() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": "Time to take meds"],
            "eventType": "MEDICATION_REMINDER"
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.title == nil)
        #expect(payload?.body == "Time to take meds")
    }

    @Test("Silent push: content-available=1")
    func contentAvailableInt() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1]
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.isContentAvailable == true)
    }

    @Test("Silent push: content-available=0 → false")
    func contentAvailableZero() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 0]
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload?.isContentAvailable == false)
    }

    @Test("Fehlender eventType → nil aber Payload existiert")
    func missingEventType() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T"]]
        ]
        let payload = APNsPayload.parse(userInfo: userInfo)
        #expect(payload != nil)
        #expect(payload?.eventType == nil)
    }
}
