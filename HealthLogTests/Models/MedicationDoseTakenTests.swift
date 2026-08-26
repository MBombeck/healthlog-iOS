import Foundation
@testable import HealthLog
import Testing

/// **H6 (AUDIT-PARITY-v11612) — actual-dose (`doseTaken`) round-trip.**
///
/// Locks the per-intake dose override on every contract surface it touches:
///  - the dose-history ledger read model decodes `intake.doseTaken`
///    (server v1.16.4) and tolerates its absence,
///  - the single-medication `POST /api/medications/{id}/intake` wire body
///    encodes it, and
///  - the bulk-entry wire body (the outbox replay shape) encodes it.
@Suite("Medication doseTaken — round-trip")
struct MedicationDoseTakenTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test("Dose-history intake decodes doseTaken when present")
    func decodesDoseTaken() throws {
        let json = Data(#"""
        {
            "from": "2026-06-01T00:00:00.000Z",
            "to": "2026-06-14T12:00:00.000Z",
            "family": "daily",
            "hasExpectedSlots": true,
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-06-13T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_on_time",
                    "intake": {
                        "id": "evt-1",
                        "scheduledFor": "2026-06-13T06:00:00.000Z",
                        "takenAt": "2026-06-13T06:05:00.000Z",
                        "skipped": false,
                        "autoMissed": false,
                        "doseTaken": "½ Tablette"
                    }
                }
            ]
        }
        """#.utf8)

        let env = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: json)
        #expect(env.rows.first?.intake?.doseTaken == "½ Tablette")
    }

    @Test("Dose-history intake tolerates an absent doseTaken (older payloads)")
    func toleratesMissingDoseTaken() throws {
        let json = Data(#"""
        {
            "from": "2026-06-01T00:00:00.000Z",
            "to": "2026-06-14T12:00:00.000Z",
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-06-13T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_on_time",
                    "intake": {
                        "id": "evt-1",
                        "scheduledFor": "2026-06-13T06:00:00.000Z",
                        "takenAt": "2026-06-13T06:05:00.000Z",
                        "skipped": false
                    }
                }
            ]
        }
        """#.utf8)

        let env = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: json)
        #expect(env.rows.first?.intake?.doseTaken == nil)
    }

    @Test("Single-medication intake body encodes doseTaken")
    func encodesIdIntakeBody() throws {
        let body = MedicationsRepository.MedicationIdIntakeBody(
            scheduledFor: Date(timeIntervalSince1970: 1_781_787_600),
            takenAt: Date(timeIntervalSince1970: 1_781_787_660),
            skipped: false,
            idempotencyKey: "key-1",
            injectionSite: nil,
            doseTaken: "1.5 mg"
        )
        let object = try encodedObject(body)
        #expect(object["doseTaken"] as? String == "1.5 mg")
        #expect(object["skipped"] as? Bool == false)
    }

    @Test("Bulk intake entry encodes doseTaken")
    func encodesBulkEntry() throws {
        let entry = MedicationsRepository.BulkIntakeEntry(
            medicationId: "med-1",
            scheduledFor: Date(timeIntervalSince1970: 1_781_787_600),
            takenAt: Date(timeIntervalSince1970: 1_781_787_660),
            skipped: false,
            idempotencyKey: "key-1",
            injectionSite: nil,
            doseTaken: "2 tablets"
        )
        let object = try encodedObject(entry)
        #expect(object["doseTaken"] as? String == "2 tablets")
        #expect(object["medicationId"] as? String == "med-1")
    }

    // MARK: - Helpers

    private func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
