import Foundation
@testable import HealthLog
import Testing

/// **W3-MEDCONTRACT (v0.14.8) — dose-history ledger wire shape.**
///
/// Locks the decode of `GET /api/medications/{id}/dose-history` against the
/// server's serialisation (`SerializedDoseHistoryRow` in
/// `dose-history/route.ts`, verified at server v1.16.4 / d56cf70d) plus the
/// tolerant-first doctrine: a minimal v1.15.18 payload and an unknown future
/// `status` literal must both decode instead of failing the whole envelope.
@Suite("MedicationDoseHistory — wire shape")
struct MedicationDoseHistoryWireTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test("Full v1.16.4 ledger payload decodes (slot + ad-hoc + pin + nearestSlot)")
    func decodesFullShape() throws {
        // Verbatim wire shape of the server route's `apiSuccess` data field:
        // slot rows graded by the band minter, an ad-hoc take carrying its
        // pin offer (`nearestSlot`), and a USER_PIN-bound slot row.
        let json = Data(#"""
        {
            "from": "2026-03-01T00:00:00.000Z",
            "to": "2026-06-01T12:00:00.000Z",
            "family": "daily",
            "hasExpectedSlots": true,
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-06-01T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "upcoming",
                    "intake": null
                },
                {
                    "kind": "slot",
                    "at": "2026-05-31T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_on_time",
                    "intake": {
                        "id": "evt-1",
                        "scheduledFor": "2026-05-31T06:00:00.000Z",
                        "takenAt": "2026-05-31T06:10:00.000Z",
                        "skipped": false,
                        "autoMissed": false
                    }
                },
                {
                    "kind": "slot",
                    "at": "2026-05-30T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_late",
                    "pinned": true,
                    "intake": {
                        "id": "evt-2",
                        "scheduledFor": "2026-05-30T06:00:00.000Z",
                        "takenAt": "2026-05-30T11:00:00.000Z",
                        "skipped": false,
                        "autoMissed": false
                    }
                },
                {
                    "kind": "slot",
                    "at": "2026-05-29T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "missed",
                    "intake": null
                },
                {
                    "kind": "ad_hoc",
                    "at": "2026-05-28T15:30:00.000Z",
                    "timeOfDay": null,
                    "status": "ad_hoc",
                    "nearestSlot": {
                        "at": "2026-05-28T06:00:00.000Z",
                        "timeOfDay": "08:00",
                        "filled": false
                    },
                    "intake": {
                        "id": "evt-3",
                        "scheduledFor": "2026-05-28T15:30:00.000Z",
                        "takenAt": "2026-05-28T15:30:00.000Z",
                        "skipped": false,
                        "autoMissed": false
                    }
                }
            ]
        }
        """#.utf8)
        let envelope = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: json)
        #expect(envelope.family == "daily")
        #expect(envelope.hasExpectedSlots == true)
        #expect(envelope.rows.count == 5)

        #expect(envelope.rows[0].status == .upcoming)
        #expect(envelope.rows[0].intake == nil)

        #expect(envelope.rows[1].status == .takenOnTime)
        #expect(envelope.rows[1].intake?.id == "evt-1")
        #expect(envelope.rows[1].timeOfDay == "08:00")

        #expect(envelope.rows[2].status == .takenLate)
        #expect(envelope.rows[2].pinned == true)

        #expect(envelope.rows[3].status == .missed)
        #expect(envelope.rows[3].intake == nil)

        let adHoc = envelope.rows[4]
        #expect(adHoc.isAdHoc)
        #expect(adHoc.status == .adHoc)
        #expect(adHoc.timeOfDay == nil)
        #expect(adHoc.nearestSlot?.timeOfDay == "08:00")
        #expect(adHoc.nearestSlot?.filled == false)
        // The pin must echo the canonical slot anchor verbatim.
        #expect(adHoc.nearestSlot?.at == Date(timeIntervalSince1970: 1_779_948_000))
    }

    @Test("Minimal v1.15.18 payload (no pinned/nearestSlot/family) still decodes")
    func decodesOlderMinimalShape() throws {
        let json = Data(#"""
        {
            "from": "2026-03-01T00:00:00.000Z",
            "to": "2026-06-01T12:00:00.000Z",
            "family": "daily",
            "hasExpectedSlots": true,
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-05-31T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "skipped",
                    "intake": {
                        "id": "evt-1",
                        "scheduledFor": "2026-05-31T06:00:00.000Z",
                        "takenAt": null,
                        "skipped": true,
                        "autoMissed": false
                    }
                }
            ]
        }
        """#.utf8)
        let envelope = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: json)
        #expect(envelope.rows.count == 1)
        #expect(envelope.rows[0].status == .skipped)
        #expect(envelope.rows[0].pinned == nil)
        #expect(envelope.rows[0].nearestSlot == nil)
        #expect(envelope.rows[0].intake?.takenAt == nil)
        #expect(envelope.rows[0].intake?.skipped == true)
    }

    @Test("Unknown future status literal degrades to nil, not a decode failure")
    func tolerantUnknownStatus() throws {
        let json = Data(#"""
        {
            "from": "2026-03-01T00:00:00.000Z",
            "to": "2026-06-01T12:00:00.000Z",
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-05-31T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_with_food",
                    "intake": null
                }
            ]
        }
        """#.utf8)
        let envelope = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: json)
        #expect(envelope.rows[0].status == nil)
        #expect(envelope.rows[0].statusRaw == "taken_with_food")
        // Optional envelope metadata absent on hypothetical lean payloads.
        #expect(envelope.family == nil)
        #expect(envelope.hasExpectedSlots == nil)
    }

    @Test("Row identity: intake id when present, slot anchor otherwise")
    func rowIdentity() {
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        let withIntake = MedicationDoseHistoryRow(
            kind: "slot",
            at: anchor,
            timeOfDay: "08:00",
            statusRaw: "taken_on_time",
            intake: .init(id: "evt-9", scheduledFor: anchor, takenAt: anchor, skipped: false)
        )
        let pureMiss = MedicationDoseHistoryRow(
            kind: "slot",
            at: anchor,
            timeOfDay: "08:00",
            statusRaw: "missed"
        )
        #expect(withIntake.id == "evt-9")
        #expect(pureMiss.id == "slot-\(anchor.timeIntervalSince1970)-08:00")
    }

    // MARK: - IntakePatch wire encode (PUT …/intake/{eventId})

    @Test("Skip patch encodes skipped:true + explicit takenAt:null, no forceSlotInstant key")
    func skipPatchShape() throws {
        let patch = MedicationsRepository.IntakePatch(
            status: "skipped",
            skipped: true,
            takenAtField: .null
        )
        let object = try encodeToObject(patch)
        #expect(object["skipped"] as? Bool == true)
        #expect(object["takenAt"] is NSNull, "skip must clear the administration instant explicitly")
        #expect(object["forceSlotInstant"] == nil, "absent must omit the key — null would unpin")
    }

    @Test("Pin patch encodes forceSlotInstant as the slot instant; unpin as explicit null")
    func pinUnpinPatchShape() throws {
        let slot = Date(timeIntervalSince1970: 1_780_000_000)
        let pin = try encodeToObject(MedicationsRepository.IntakePatch(forceSlotInstant: .value(slot)))
        #expect(pin["forceSlotInstant"] is String)
        #expect(pin["takenAt"] == nil, "pin must not touch takenAt")

        let unpin = try encodeToObject(MedicationsRepository.IntakePatch(forceSlotInstant: .null))
        #expect(unpin["forceSlotInstant"] is NSNull)
    }

    @Test("IntakePatch outbox payload round-trips through decode (pre-v0.14.8 rows replay)")
    func patchRoundTrip() throws {
        let taken = Date(timeIntervalSince1970: 1_780_000_000)
        let original = MedicationsRepository.IntakePatch(
            status: "taken",
            takenAt: taken,
            skipped: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundtripDecoder = JSONDecoder()
        roundtripDecoder.dateDecodingStrategy = .iso8601
        let decoded = try roundtripDecoder.decode(
            MedicationsRepository.IntakePatch.self,
            from: encoder.encode(original)
        )
        #expect(decoded == original)
        // Legacy pre-v0.14.8 outbox row: `{status, takenAt}` only.
        let legacy = try roundtripDecoder.decode(
            MedicationsRepository.IntakePatch.self,
            from: Data(#"{"status":"taken","takenAt":"2026-06-01T08:00:00Z"}"#.utf8)
        )
        #expect(legacy.status == "taken")
        #expect(legacy.skipped == nil)
        #expect(legacy.forceSlotInstant == .absent)
    }

    private func encodeToObject(_ patch: MedicationsRepository.IntakePatch) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(patch)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object ?? [:]
    }
}
