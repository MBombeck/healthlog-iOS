import Foundation
@testable import HealthLog
import os
import Testing

/// A dose bulk that failed must be re-sent under a key derived from the doses
/// themselves, so a sweep after a relaunch lets the server deduplicate instead
/// of writing a second intake row.
@Suite("Apple Health doses — restart-stable bulk retry identity", .serialized, .mockURLSession)
struct AppleHealthDoseRetryIdentityTests {
    @Test("a failed dose bulk is re-sent under the key derived from its dose UUIDs")
    func failedBulkReplaysUnderTheDerivedKey() async throws {
        let (api, keychain) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        let bulkKeys = OSAllocatedUnfairLock(initialState: [String]())
        MockURLProtocol.install { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = recorder.mirrorPostCount == 0
                    ? []
                    : [(id: "srv-concept-A", name: "Med", externalId: Optional("concept-A"))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            if path == "/api/medications" {
                return (MedFixtures.ok(req), Data(MedFixtures.medEnvelope(id: "srv-concept-A", name: "Med").utf8))
            }
            bulkKeys.withLock { $0.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "") }
            let json = #"{"data":null,"error":"boom"}"#
            return (MedFixtures.status(500, req), Data(json.utf8))
        }
        let dose = AppleHealthDoseRecord(
            eventUUID: "DOSE-UUID-R",
            conceptIdentifier: "concept-A",
            logStatus: .taken,
            scheduledAt: Date(timeIntervalSince1970: 1_783_000_000),
            takenAt: Date(timeIntervalSince1970: 1_783_000_300)
        )
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: "concept-A", name: "Med")],
            doses: [dose]
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: keychain, reader: reader)

        let first = await fixture.importer.sync()
        let sentInFirstPass = bulkKeys.withLock { $0.count }
        let second = await fixture.importer.sync()

        #expect(first.failedBatches == 1)
        #expect(second.failedBatches == 1)
        #expect(fixture.ledger.pendingIdentities() == ["DOSE-UUID-R"], "a failed bulk settles nothing")
        let expected = try #require(
            HealthSyncRetryEnvelope(
                ownerID: MedFixtures.ownerID,
                source: .appleMedication,
                stableIdentity: "DOSE-UUID-R"
            )
        )
        // The client retries within one pass; the second pass must send the same
        // number of attempts again, every one under the same derived key.
        let keys = bulkKeys.withLock { $0 }
        #expect(sentInFirstPass > 0)
        #expect(keys.count == 2 * sentInFirstPass, "the second pass must re-send the held bulk")
        #expect(keys.allSatisfy { $0 == expected.idempotencyKey })
    }
}
