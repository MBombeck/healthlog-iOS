import Foundation
@testable import HealthLog
import Testing

/// E1 — the "Track intake" switch on the add sheet (v1.39.1 #1033).
///
/// The web offers the switch in its wizard summary; D1 put it into the editor
/// only. The add sheet now offers it too, under the same rule as the editor:
/// only against a server that knows the field, recognised the way D1
/// recognises it — the served medications carry `trackIntake`. A new
/// medication starts tracked (the server default), so only a switch turned off
/// is sent; an older server never sees the field. Fixtures are the v1.39.1 and
/// v1.39.0 `MedicationListEntry` shapes from `MedicationTrackIntakeV1391Tests`.
@Suite("v1.39.1 #1033 — track intake when adding a medication")
struct MedicationAddTrackIntakeTests {
    private static func v1391List() throws -> [Medication] {
        try [MedicationTrackIntakeV1391Tests.tracked()]
    }

    private static func v1390List() throws -> [Medication] {
        try [MedicationTrackIntakeV1391Tests.decode(MedicationTrackIntakeV1391Tests.medicationJSON(
            trackIntake: nil,
            schedules: [MedicationTrackIntakeV1391Tests.schedule("08:00")]
        ))]
    }

    @Test("a v1.39.1 server is recognised by its served medications; an older one or an empty list is not")
    func serverSupportFollowsTheServedRows() throws {
        #expect(try Medication.serverKnowsTrackIntake(Self.v1391List()))
        #expect(try Medication.serverKnowsTrackIntake([MedicationTrackIntakeV1391Tests.recordOnly()]))
        #expect(try !Medication.serverKnowsTrackIntake(Self.v1390List()))
        #expect(!Medication.serverKnowsTrackIntake([]))
    }

    @Test("switched off against v1.39.1 the create names trackIntake false; left on it names nothing")
    func createNamesOnlyAnOffSwitch() throws {
        #expect(try MedicationTrackIntakeWrite.create(switchOn: false, served: Self.v1391List()) == false)
        #expect(try MedicationTrackIntakeWrite.create(switchOn: true, served: Self.v1391List()) == nil)
        #expect(try MedicationTrackIntakeWrite.create(switchOn: false, served: Self.v1390List()) == nil)
        #expect(MedicationTrackIntakeWrite.create(switchOn: false, served: []) == nil)
    }

    @Test("the create body carries trackIntake only when set, and a queued create from an older build still reads")
    func createBodyWireShape() throws {
        let off = MedicationsRepository.MedicationCreate(name: "Atorvastatin 20", dose: "20 mg", trackIntake: false)
        let offJSON = try #require(String(data: JSONEncoder.hlDefault.encode(off), encoding: .utf8))
        #expect(offJSON.contains(#""trackIntake":false"#))

        let unset = MedicationsRepository.MedicationCreate(name: "Atorvastatin 20", dose: "20 mg")
        let unsetJSON = try #require(String(data: JSONEncoder.hlDefault.encode(unset), encoding: .utf8))
        #expect(!unsetJSON.contains("trackIntake"))

        // An outbox row written before E1 has no such key.
        let legacy = Data(#"{"body":{"name":"Atorvastatin 20","dose":"20 mg","active":true}}"#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.CreateMedication.self, from: legacy)
        #expect(decoded.body.trackIntake == nil)
        #expect(decoded.body.name == "Atorvastatin 20")
    }
}
