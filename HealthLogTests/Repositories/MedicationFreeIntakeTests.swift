import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 6.1 — free / back-dated intake logging contract.**
///
/// Drives the REAL `APIClient` (not a mock-server) through `MockURLProtocol` per
/// PROJECT_GUIDE.md ("echten APIClient mit Stub-URLSession nutzen, sonst entgehen uns
/// Schema-Drift-Bugs") so the wire body + idempotency header + outbox replay go
/// over the exact production request-building path.
///
/// Locks three invariants:
///  1. the `POST /api/medications/{id}/intake` body carries the free-log fields
///     (`takenAt` / `scheduledFor` / `skipped` / `doseTaken` / `forceSlotInstant`)
///     and — Issue #64 — carries **no `source`** field,
///  2. a retriable failure enqueues the exact body on the outbox under
///     `.logMedicationIntake`, and
///  3. the outbox replay re-POSTs under the SAME idempotency key so the server
///     dedup folds a write that may already have landed.
@MainActor
@Suite("Medication free intake — Build 6.1", .serialized)
struct MedicationFreeIntakeTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private nonisolated func intakeResponseJSON() -> String {
        #"""
        {"data":{"id":"evt-1","medicationId":"med-1","scheduledFor":"2026-06-13T06:00:00.000Z","takenAt":"2026-06-13T06:05:00.000Z","skipped":false}}
        """#
    }

    @Test("logIntake POSTs the free-log body with no `source` field + an Idempotency-Key")
    func postsFreeLogBodyWithoutSource() async throws {
        let api = makeClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedIdem: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedMethod = req.httpMethod
            capturedPath = req.url?.path
            capturedIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            capturedBody = req.httpBody ?? Self.readStream(req.httpBodyStream)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(intakeResponseJSON().utf8)
            )
        }

        let taken = Date(timeIntervalSince1970: 1_781_762_700)
        let intake = try await repo.logIntake(
            medicationId: "med-1",
            scheduledFor: taken,
            takenAt: taken,
            skipped: false,
            doseTaken: "½ Tablette",
            injectionSite: nil,
            forceSlotInstant: nil
        )

        #expect(intake.id == "evt-1")
        #expect(capturedMethod == "POST")
        #expect(capturedPath == "/api/medications/med-1/intake")
        #expect(capturedIdem != nil, "the per-med intake POST must carry an Idempotency-Key header")

        let object = try #require(try JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any])
        // Issue #64 — the client NEVER sends a provenance `source`; the server
        // derives it from the request context.
        #expect(object["source"] == nil, "Issue #64: the intake body must carry no `source` field")
        #expect(object["skipped"] as? Bool == false)
        #expect(object["takenAt"] is String, "back-dated administration instant is on the wire")
        #expect(object["scheduledFor"] is String, "the slot the dose belongs to is on the wire")
        #expect(object["doseTaken"] as? String == "½ Tablette")
        // A body-level idempotency key mirrors the header for the server's
        // `intake_events` UNIQUE-key dedup.
        #expect(object["idempotencyKey"] as? String == capturedIdem)
    }

    @Test("A skip drops takenAt + doseTaken from the wire body")
    func skipDropsTakenAtAndDose() async throws {
        let api = makeClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = req.httpBody ?? Self.readStream(req.httpBodyStream)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"evt-2","medicationId":"med-1","scheduledFor":"2026-06-13T06:00:00.000Z","skipped":true}}"#.utf8)
            )
        }

        _ = try await repo.logIntake(
            medicationId: "med-1",
            scheduledFor: Date(timeIntervalSince1970: 1_781_762_700),
            takenAt: Date(timeIntervalSince1970: 1_781_762_700),
            skipped: true,
            doseTaken: "½ Tablette"
        )

        let object = try #require(try JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any])
        #expect(object["skipped"] as? Bool == true)
        #expect(object["takenAt"] == nil, "a skip carries no administration instant")
        #expect(object["doseTaken"] == nil, "a skip carries no dose override")
        #expect(object["source"] == nil)
    }

    @Test("forceSlotInstant is sent when set, omitted when nil")
    func forceSlotInstantOmittedWhenNil() throws {
        let withPin = MedicationsRepository.MedicationIdIntakeBody(
            scheduledFor: nil,
            takenAt: Date(timeIntervalSince1970: 1_781_762_700),
            skipped: false,
            idempotencyKey: "k",
            forceSlotInstant: Date(timeIntervalSince1970: 1_781_760_000)
        )
        let withPinObj = try encodedObject(withPin)
        #expect(withPinObj["forceSlotInstant"] is String)

        let noPin = MedicationsRepository.MedicationIdIntakeBody(
            scheduledFor: nil,
            takenAt: Date(timeIntervalSince1970: 1_781_762_700),
            skipped: false,
            idempotencyKey: "k"
        )
        let noPinObj = try encodedObject(noPin)
        #expect(noPinObj["forceSlotInstant"] == nil, "nil forceSlotInstant is omitted (server attributes by band)")
        #expect(noPinObj["source"] == nil)
    }

    @Test("A retriable failure enqueues the body; replay re-POSTs under the persisted idempotency key")
    func retriableEnqueuesAndReplayReusesKey() async throws {
        let api = makeClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)

        // 1) Live call hits a retriable 503 → repo enqueues on the outbox.
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        await #expect(throws: HLError.self) {
            _ = try await repo.logIntake(
                medicationId: "med-1",
                scheduledFor: nil,
                takenAt: Date(timeIntervalSince1970: 1_781_762_700),
                skipped: false
            )
        }

        let snap = await outbox.snapshot
        #expect(snap.count == 1, "a retriable failure must enqueue exactly one op")
        let op = try #require(snap.first)
        #expect(op.kind == .logMedicationIntake)
        let payload = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.LogMedicationIntake.self, from: op.payload)
        #expect(payload.medicationId == "med-1")
        // The body persisted the same idempotency key the header will carry.
        #expect(payload.body.idempotencyKey == op.idempotencyKey)

        // 2) Replay re-POSTs under the persisted key.
        nonisolated(unsafe) var replayIdem: String?
        nonisolated(unsafe) var replayPath: String?
        MockURLProtocol.handler = { req in
            replayIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            replayPath = req.url?.path
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(intakeResponseJSON().utf8)
            )
        }
        _ = try await repo.replayLogIntake(
            medicationId: payload.medicationId,
            body: payload.body,
            idempotencyKey: op.idempotencyKey
        )
        #expect(replayPath == "/api/medications/med-1/intake")
        #expect(replayIdem == op.idempotencyKey, "replay must reuse the persisted key so server dedup folds it")
    }

    // MARK: - Helpers

    private func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 1024)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
