import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// AUDIT-G A1-B1 (v0.11) — decode contract for `GET /api/auth/me/notification-prefs`.
///
/// This is the ONLY endpoint that carries `mood.reminderHour` (the source of
/// truth for the evening mood reminder); `/api/notifications/preferences`
/// returns no `mood` block. The cold-read of the hour was switched onto this
/// shape so a fresh launch sees the server-canonical hour instead of silently
/// falling to the local default 22.
@Suite("AuthNotificationPrefsPayload — auth/me decode")
struct AuthNotificationPrefsPayloadTests {
    @Test("decodes the fully-resolved {medication, mood:{reminderHour}} shape")
    func decodesFullShape() throws {
        let json = """
        {
            "medication": { "clientManaged": false, "deliveryDefault": "server" },
            "mood": { "reminderHour": 8 }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.mood?.reminderHour == 8)
        #expect(decoded.moodReminderHour == 8)
    }

    @Test("ignores unknown sibling categories (forward-compat)")
    func ignoresUnknownSiblings() throws {
        // A future server may grow new categories next to medication/mood.
        let json = """
        {
            "medication": { "clientManaged": true, "deliveryDefault": "client" },
            "mood": { "reminderHour": 21 },
            "personalRecords": { "enabled": true }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.moodReminderHour == 21)
    }

    @Test("clamps an out-of-range hour")
    func clampsOutOfRange() throws {
        let json = """
        { "mood": { "reminderHour": 99 } }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.moodReminderHour == 23)
    }

    @Test("missing mood block yields nil so the local mirror is preserved")
    func missingMoodIsNil() throws {
        // A drifted / older server omits mood entirely — the caller must keep
        // its local mirror rather than overwrite it with a guess.
        let json = """
        { "medication": { "clientManaged": false, "deliveryDefault": "server" } }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(AuthNotificationPrefsPayload.self, from: data)
        #expect(decoded.mood == nil)
        #expect(decoded.moodReminderHour == nil)
    }
}
