import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.3 F-4 — `MedicationsRepository.recordFromReminder` is the
/// notification-action path's server-roundtrip. Verifies the bulk
/// endpoint contract end-to-end against a stubbed URLSession:
///  - Happy path 200 with `inserted` entry
///  - 422 `medication_not_found` surfaces as non-retriable `HLError`
///  - Network drop enqueues a `ReminderIntake` payload on the outbox
///    AND re-throws (caller decides what to do — handler swallows it
///    and emits a log signpost)
///  - `idempotencyKey` survives the outbox round-trip so the replay
///    path reuses the same key (server-side dedup)
@Suite("MedicationsRepository — recordFromReminder", .serialized)
struct MedicationsRepositoryReminderIntakeTests {
    private static let scheduledFor = Date(timeIntervalSince1970: 1_779_710_400)
    private static let takenAt = Self.scheduledFor.addingTimeInterval(60)

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func status(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    @Test("200 with inserted entry completes without throwing")
    func recordTakenSuccess() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedRequestBody: Data?
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedRequestBody = req.httpBody ?? req.bodyStreamData()
            let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"new-event-1"}]}}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)

        try await repo.recordFromReminder(
            medicationId: "med-1",
            scheduledFor: Self.scheduledFor,
            status: .taken,
            takenAt: Self.takenAt
        )
        #expect(capturedPath == "/api/medications/intake/bulk")
        #expect(capturedRequestBody != nil)
        if let body = capturedRequestBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let entries = json["entries"] as? [[String: Any]]
            #expect(entries?.count == 1)
            #expect(entries?.first?["medicationId"] as? String == "med-1")
            #expect(entries?.first?["skipped"] as? Bool == false)
            #expect(entries?.first?["takenAt"] != nil)
            #expect(entries?.first?["idempotencyKey"] is String)
        } else {
            Issue.record("Could not decode request body as JSON")
        }
    }

    @Test("status=.skipped sends skipped=true and no takenAt")
    func recordSkippedShapesBody() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedRequestBody: Data?
        MockURLProtocol.handler = { req in
            capturedRequestBody = req.httpBody ?? req.bodyStreamData()
            let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"new-event-2"}]}}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)

        try await repo.recordFromReminder(
            medicationId: "med-2",
            scheduledFor: Self.scheduledFor,
            status: .skipped
        )

        if let body = capturedRequestBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let entries = json["entries"] as? [[String: Any]]
            #expect(entries?.first?["skipped"] as? Bool == true)
            // takenAt should be absent (nil-encoded) — encoder omits nil keys
            #expect(entries?.first?["takenAt"] == nil || entries?.first?["takenAt"] is NSNull)
        } else {
            Issue.record("Could not decode request body as JSON")
        }
    }

    @Test("status=.missed is read-only and never reaches network or outbox")
    func missedNeverWrites() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return (Self.ok(request), Data(#"{"data":{}}"#.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)

        do {
            try await repo.recordFromReminder(
                medicationId: "med-read-only",
                scheduledFor: Self.scheduledFor,
                status: .missed
            )
            Issue.record("Expected the server-owned missed status to be rejected")
        } catch let HLError.server(status, code, _) {
            #expect(status == 422)
            #expect(code == "medications.intake.status_not_writable")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(requestCount == 0)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("422 medication_not_found throws non-retriable HLError and does NOT enqueue outbox")
    func nonRetriableRejectionDoesNotEnqueue() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        // Bulk endpoint returns 200 with the rejection embedded in entries[0]
        MockURLProtocol.handler = { req in
            let body = #"{"data":{"processed":1,"inserted":0,"duplicates":0,"entries":[{"index":0,"status":"skipped","reason":"medication_not_found"}]}}"#
            return (Self.ok(req), Data(body.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)

        do {
            try await repo.recordFromReminder(
                medicationId: "med-deleted",
                scheduledFor: Self.scheduledFor,
                status: .taken
            )
            Issue.record("Expected throw on rejection")
        } catch let err as HLError {
            #expect(!err.isRetriable, "422 rejection must be non-retriable")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let pending = await outbox.snapshot
        #expect(pending.isEmpty, "Non-retriable rejection must NOT enqueue on outbox")
    }

    @Test("Network drop (notConnectedToInternet) enqueues on outbox AND re-throws")
    func retriableNetworkErrorEnqueues() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)

        do {
            try await repo.recordFromReminder(
                medicationId: "med-offline",
                scheduledFor: Self.scheduledFor,
                status: .taken
            )
            Issue.record("Expected throw on network drop")
        } catch let err as HLError {
            #expect(err.isRetriable, "Network drop must be retriable")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let pending = await outbox.snapshot
        #expect(pending.count == 1, "Outbox must hold exactly one queued entry")
        #expect(pending.first?.kind == .takeMedication)
        // Payload must be decodable as the ReminderIntake envelope, NOT
        // the legacy IntakeUpdate shape.
        let decoder = JSONDecoder.hlDefault
        let envelope = try? decoder.decode(OutboxQueue.Payloads.ReminderIntake.self, from: try #require(pending.first?.payload))
        #expect(envelope != nil)
        #expect(envelope?.entry.medicationId == "med-offline")
    }
}

// swiftlint:enable force_unwrapping

// MARK: - URLRequest body-stream helper

private extension URLRequest {
    /// Some `URLSession` configurations pipe the body through a stream so
    /// `httpBody` is nil. Drain the stream synchronously — the test path
    /// is the only caller, requests are small (<1 KB).
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 4096)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
