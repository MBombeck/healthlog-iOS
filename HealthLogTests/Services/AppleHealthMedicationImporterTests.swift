import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #47** — drives ``AppleHealthMedicationImporter`` over the **real**
/// ``APIClient`` + `MockURLProtocol` + a real ``MedicationsRepository`` (per
/// PROJECT_GUIDE.md — no mock server on the write paths). Covers the mirror
/// upsert: idempotency, adoption of a server-known row, the rename follow, the
/// CU-10 unstable-`externalId` refusal, and the v1.32.25 mirror cap.
///
/// The dose-import half lives in `AppleHealthMedicationDoseImportTests`; both
/// share `MedFixtures`.
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("AppleHealthMedicationImporter — medication mirror", .serialized)
struct AppleHealthMedicationImporterTests {
    // MARK: - Mirror upsert idempotency

    @Test("Mirror POSTs /api/medications with externalSource + externalId; a known concept is not re-posted")
    func mirrorUpsertSkipsKnownConcept() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        // The server list starts empty and gains the mirrored row once created —
        // exactly what the next sweep's reconcile reads back.
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = recorder.mirrorPostCount == 0
                    ? []
                    : [(id: "srv-\(MedFixtures.conceptA)", name: "Lisinopril", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            if path == "/api/medications" {
                let externalId = recorder.lastMirrorExternalId ?? "x"
                let json = MedFixtures.medEnvelope(id: "srv-\(externalId)", name: "Lisinopril")
                return (MedFixtures.ok(req), Data(json.utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Lisinopril")],
            doses: []
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, registry) = (fixture.importer, fixture.registry)

        // First sweep — the server holds nothing yet, so the mirror is created.
        let first = await importer.sync()
        #expect(first.medicationsMirrored == 1)
        #expect(first.medicationsSkippedKnown == 0)
        // The mirror POST carried the contract fields.
        let body = try #require(recorder.lastMirrorBody)
        #expect(body["externalSource"] as? String == "APPLE_HEALTH")
        #expect(body["externalId"] as? String == MedFixtures.conceptA)
        // The registry mapped concept → server id.
        #expect(registry.medicationId(forConcept: MedFixtures.conceptA) == "srv-\(MedFixtures.conceptA)")

        // Second sweep — the GET now reports the row as APPLE_HEALTH-mirrored, so
        // the create is skipped. This is the whole point of CU-10: server
        // idempotency is the backstop, not the primary dedup mechanism.
        let second = await importer.sync()
        #expect(second.medicationsMirrored == 0)
        #expect(second.medicationsSkippedKnown == 1)
        #expect(recorder.mirrorPostCount == 1, "a known concept must not be re-posted on every sweep")
        #expect(registry.medicationId(forConcept: MedFixtures.conceptA) == "srv-\(MedFixtures.conceptA)")
    }

    @Test("A mirror the server already holds is adopted without any POST")
    func adoptsServerKnownMirrorWithoutPost() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = [(id: "srv-existing", name: "Lisinopril", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Lisinopril")],
            doses: []
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, registry) = (fixture.importer, fixture.registry)

        let summary = await importer.sync()
        #expect(summary.medicationsMirrored == 0)
        #expect(summary.medicationsSkippedKnown == 1)
        #expect(recorder.mirrorPostCount == 0)
        #expect(registry.medicationId(forConcept: MedFixtures.conceptA) == "srv-existing")
    }

    @Test("A renamed Health-app medication is re-posted so the mirror follows")
    func changedConceptIsReposted() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = [(id: "srv-existing", name: "Lisinopril", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            if path == "/api/medications" {
                return (MedFixtures.ok(req), Data(MedFixtures.medEnvelope(id: "srv-existing", name: "Lisinopril 5mg").utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Lisinopril 5mg")],
            doses: []
        )
        let importer = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader).importer

        let summary = await importer.sync()
        #expect(summary.medicationsMirrored == 1)
        #expect(summary.medicationsSkippedKnown == 0)
        #expect(recorder.mirrorPostCount == 1)
    }

    // MARK: - CU-10 — unstable externalId + mirror cap

    @Test("A pointer-shaped externalId is refused pre-flight — nothing goes on the wire")
    func unstableExternalIdRefusedBeforeThePost() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope([]).utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        // Exactly the value the defective build produced.
        let poisoned = "<HKHealthConceptIdentifier: 0x12568db80>"
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: poisoned, name: "Lisinopril")],
            doses: []
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, registry) = (fixture.importer, fixture.registry)

        let summary = await importer.sync()
        #expect(summary.medicationsMirrored == 0)
        #expect(summary.unstableExternalIDRejections == 1)
        #expect(summary.medicationsFailed == 1)
        #expect(summary.issue == .unstableExternalId)
        #expect(recorder.mirrorPostCount == 0, "a phantom-minting id must never reach the server")
        #expect(registry.medicationId(forConcept: poisoned) == nil)
    }

    @Test("A 422 medications.mirror.limit_exceeded becomes its own explained state")
    func mirrorLimitExceeded() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope([]).utf8))
            }
            if path == "/api/medications" {
                let json = #"""
                {"data":null,"error":"This account already mirrors the maximum number of medications from an external source",
                "meta":{"errorCode":"medications.mirror.limit_exceeded"}}
                """#
                return (MedFixtures.status(422, req), Data(json.utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Lisinopril")],
            doses: []
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, registry) = (fixture.importer, fixture.registry)

        let summary = await importer.sync()
        #expect(summary.mirrorLimitRejections == 1)
        #expect(summary.medicationsMirrored == 0)
        #expect(summary.issue == .limitReached)
        // Not a mapping — the row was never created.
        #expect(registry.medicationId(forConcept: MedFixtures.conceptA) == nil)
    }

    @Test("A per-entry unstable_external_id skip does not fail the batch")
    func bulkTolleratesUnstableExternalIdSkip() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = [(id: "srv-existing", name: "Med", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            // One entry refused, the rest of the batch lands (server v1.32.37).
            let json = #"""
            {"data":{"processed":2,"inserted":1,"updated":0,"duplicates":0,
            "skipped":[{"index":1,"reason":"unstable_external_id"}],
            "entries":[{"index":0,"status":"inserted","id":"intake-1"},
            {"index":1,"status":"skipped","reason":"unstable_external_id"}]},"error":null}
            """#
            return (MedFixtures.ok(req), Data(json.utf8))
        }
        let doses = [
            AppleHealthDoseRecord(
                eventUUID: "8AD2A9CB-3F0C-4E4D-9C1E-4B7E2A1D6F30",
                conceptIdentifier: MedFixtures.conceptA,
                logStatus: .taken,
                scheduledAt: Date(timeIntervalSince1970: 1_783_000_000),
                takenAt: Date(timeIntervalSince1970: 1_783_000_300)
            ),
            AppleHealthDoseRecord(
                eventUUID: "3F0C4E4D-9C1E-4B7E-2A1D-6F30AD2A9CB1",
                conceptIdentifier: MedFixtures.conceptA,
                logStatus: .taken,
                scheduledAt: Date(timeIntervalSince1970: 1_783_000_600),
                takenAt: Date(timeIntervalSince1970: 1_783_000_900)
            )
        ]
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Med")],
            doses: doses
        )
        let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader)
        let (importer, registry, ledger) = (fixture.importer, fixture.registry, fixture.ledger)

        let summary = await importer.sync()
        #expect(summary.dosesInserted == 1, "the rest of the batch landed")
        #expect(summary.dosesSkipped == 1)
        #expect(summary.dosesSkippedUnstableExternalID == 1)
        #expect(summary.failedBatches == 0, "one refused entry must never fail the whole batch")
        #expect(summary.issue == .unstableExternalId)
        // The refusal is deterministic — leaving the entry pending would re-offer
        // it forever, so `unstable_external_id` settles the dose exactly as it
        // settled the watermark before plan 07-05. Both doses are accounted for.
        #expect(ledger.pendingIdentities().isEmpty)
        #expect(registry.doseCursor() == nil, "the legacy watermark is frozen, never written")
    }

    @Test("A clean sweep reports no user-facing issue")
    func cleanSweepHasNoIssue() async throws {
        let (api, kc) = MedFixtures.makeAPI()
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                let rows = [(id: "srv-existing", name: "Med", externalId: Optional(MedFixtures.conceptA))]
                return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope(rows).utf8))
            }
            return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: MedFixtures.conceptA, name: "Med")],
            doses: []
        )
        let importer = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader).importer

        let summary = await importer.sync()
        #expect(summary.issue == nil)
    }

    // MARK: - Gates

    @Test("No auth token short-circuits before any read or POST")
    func noTokenGate() async throws {
        let (api, kc) = MedFixtures.makeAPI(token: nil)
        let recorder = MedicationRequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (MedFixtures.ok(req), Data())
        }
        let reader = FakeMedicationReader(
            medications: [AppleHealthMedicationRecord(conceptIdentifier: "c", name: "n")],
            doses: []
        )
        let importer = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader).importer
        let summary = await importer.sync()
        #expect(summary == .zero)
        #expect(recorder.requestCount == 0)
        #expect(reader.medicationReadCount == 0, "no HK read when pre-login")
    }
}

// swiftlint:enable force_unwrapping
