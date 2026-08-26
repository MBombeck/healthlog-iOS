import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #47 / Phase 07 plan 07-05** — the Apple-Health dose-import half.
///
/// Split out of `AppleHealthMedicationImporterTests` when per-dose progression
/// replaced the date watermark: these are the cases that assert what the sweep
/// *remembers*, and they now read ``AppleHealthDoseLedger`` rather than a
/// `Date` cursor.
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("AppleHealthMedicationImporter — dose import", .serialized)
struct AppleHealthMedicationDoseImportTests {
    // MARK: - Dose bulk source/externalId + duplicate replay

    @Test("Dose bulk carries source + externalId; a replay reports duplicate and advances the cursor")
    func doseBulkSourceExternalIdAndDuplicateReplay() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        // First bulk → inserted; every later bulk → duplicate (replay).
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = recorder.mirrorPostCount == 0
                    ? []
                    : [(id: "srv-concept-A", name: "Med", externalId: Optional("concept-A"))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            if path == "/api/medications" {
                let externalId = recorder.lastMirrorExternalId ?? "x"
                return (MedFixtures.ok(req), Data(MedFixtures.medEnvelope(id: "srv-\(externalId)", name: "Med").utf8))
            }
            // Bulk intake.
            let status = recorder.bulkPostCount == 1 ? "inserted" : "duplicate"
            let inserted = status == "inserted" ? 1 : 0
            let dup = status == "duplicate" ? 1 : 0
            let json = #"""
            {"data":{"processed":1,"inserted":\#(inserted),"updated":0,"duplicates":\#(dup),
            "skipped":[],"entries":[{"index":0,"status":"\#(status)","id":"intake-1"}]},"error":null}
            """#
            return (MedFixtures.ok(req), Data(json.utf8))
        }
        let dose = AppleHealthDoseRecord(
            eventUUID: "DOSE-UUID-1",
            conceptIdentifier: "concept-A",
            logStatus: .taken,
            scheduledAt: Date(timeIntervalSince1970: 1_783_000_000),
            takenAt: Date(timeIntervalSince1970: 1_783_000_300),
            doseQuantity: 2,
            doseUnit: "tablet"
        )
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: "concept-A", name: "Med")],
            doses: [dose]
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, ledger) = (fixture.importer, fixture.ledger)

        // First sweep → inserted.
        let first = await importer.sync()
        #expect(first.dosesInserted == 1)
        let entry = try #require(recorder.lastBulkFirstEntry)
        #expect(entry["source"] as? String == "APPLE_HEALTH")
        #expect(entry["externalId"] as? String == "DOSE-UUID-1")
        #expect(entry["medicationId"] as? String == "srv-concept-A")
        #expect(entry["doseTaken"] as? String == "2 tablet")
        // The dose is settled by identity, and the ledger's horizon reached its
        // instant. Nothing is pending, so the next read resumes at the horizon.
        #expect(ledger.pendingIdentities().isEmpty)
        #expect(ledger.resumeInstant() == dose.recordedAt)

        // Second sweep — the fake reader returns the SAME dose (a replay). The
        // server reports `duplicate`; the importer counts it as landed and never
        // retries in a loop.
        let bulkCountBefore = recorder.bulkPostCount
        let second = await importer.sync()
        #expect(second.dosesDuplicate == 1)
        #expect(second.dosesInserted == 0)
        #expect(recorder.bulkPostCount == bulkCountBefore + 1, "one replay POST, not a retry loop")
    }

    // MARK: - apple_health_not_mirrored 422

    @Test("A 422 apple_health_not_mirrored stops the run without advancing the cursor")
    func notMirrored422StopsRun() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope([]).utf8))
            }
            if path == "/api/medications" {
                let externalId = recorder.lastMirrorExternalId ?? "x"
                return (MedFixtures.ok(req), Data(MedFixtures.medEnvelope(id: "srv-\(externalId)", name: "Med").utf8))
            }
            let json = #"""
            {"data":null,"error":"Apple Health medication is not mirrored",
            "meta":{"errorCode":"medications.intake.bulk.apple_health_not_mirrored"}}
            """#
            return (MedFixtures.status(422, req), Data(json.utf8))
        }
        let dose = AppleHealthDoseRecord(
            eventUUID: "DOSE-UUID-2",
            conceptIdentifier: "concept-A",
            logStatus: .taken,
            scheduledAt: Date(timeIntervalSince1970: 1_783_000_000),
            takenAt: Date(timeIntervalSince1970: 1_783_000_300)
        )
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: "concept-A", name: "Med")],
            doses: [dose]
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, ledger) = (fixture.importer, fixture.ledger)

        let summary = await importer.sync()
        #expect(summary.notMirroredRejections == 1)
        #expect(summary.dosesInserted == 0)
        // The dose stays pending by identity — it retries once the med truly
        // mirrors, and the next read resumes *at* its instant rather than past it.
        #expect(ledger.pendingIdentities() == ["DOSE-UUID-2"])
        #expect(ledger.resumeInstant() == dose.recordedAt)
    }

    @Test("The repository surfaces the 422 errorCode as HLError.server")
    func repositorySurfaces422Code() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        MockURLProtocol.handler = { req in
            let json = #"""
            {"data":null,"error":"not mirrored",
            "meta":{"errorCode":"medications.intake.bulk.apple_health_not_mirrored"}}
            """#
            return (MedFixtures.status(422, req), Data(json.utf8))
        }
        _ = kc
        let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let entry = MedicationsRepository.BulkIntakeEntry(
            medicationId: "srv-1",
            scheduledFor: Date(timeIntervalSince1970: 1_783_000_000),
            takenAt: Date(timeIntervalSince1970: 1_783_000_000),
            skipped: false,
            idempotencyKey: nil,
            source: "APPLE_HEALTH",
            externalId: "DOSE-X"
        )
        await #expect(throws: HLError.self) {
            _ = try await repo.bulkImportAppleHealthDoses([entry])
        }
    }
}

// swiftlint:enable force_unwrapping
