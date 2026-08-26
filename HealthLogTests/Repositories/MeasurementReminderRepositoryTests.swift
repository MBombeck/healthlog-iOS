import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-REMINDERS (#23 v1.18.1) — pins the `MeasurementReminderRepository` wire
/// contract against the live server routes: list / create / patch / delete /
/// satisfy hit the right method + path and unwrap the `{ data, error, meta }`
/// envelope. Uses the real `APIClient` over a `MockURLProtocol` session (per the
/// PROJECT_GUIDE.md doctrine — never a hand-rolled mock server) so envelope-shape drift
/// is caught.
@Suite("MeasurementReminderRepository", .serialized)
struct MeasurementReminderRepositoryTests {
    private struct RecordedCall {
        let method: String
        let path: String
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [RecordedCall] = []
        func record(method: String, path: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(RecordedCall(method: method, path: path))
        }

        var snapshot: [RecordedCall] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private func makeRepo() -> MeasurementReminderRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return MeasurementReminderRepository(api: api)
    }

    private static func rowJSON(id: String, origin: String = "VORSORGE") -> String {
        """
        {"id":"\(id)","label":"Annual blood test","measurementType":"WEIGHT",
         "intervalDays":30,"rrule":null,"anchorDate":null,"endsOn":null,
         "origin":"\(origin)","notifyHour":9,"location":null,
         "nextDueAt":"2026-07-01T09:00:00.000Z","lastSatisfiedAt":null,"enabled":true,
         "createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-06-01T09:00:00.000Z"}
        """
    }

    @Test("list GETs /api/measurement-reminders and unwraps the list envelope")
    func listRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            let payload = Data("{\"data\":[\(Self.rowJSON(id: "r1")),\(Self.rowJSON(id: "r2", origin: "COACH"))]}".utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let rows = try await repo.list()

        #expect(rows.count == 2)
        #expect(rows.first?.origin == .vorsorge)
        #expect(rows.last?.origin == .coach)
        let call = try #require(log.snapshot.first)
        #expect(call.method == "GET")
        #expect(call.path == "/api/measurement-reminders")
    }

    @Test("create POSTs the create body and unwraps the created envelope")
    func createRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":\(Self.rowJSON(id: "new-1"))}".utf8)
            )
        }

        let created = try await repo.create(
            MeasurementReminderCreate(label: "Annual blood test", measurementType: "WEIGHT", intervalDays: 30)
        )

        #expect(created.id == "new-1")
        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/measurement-reminders")
    }

    @Test("update PATCHes /api/measurement-reminders/{id}")
    func updateRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":\(Self.rowJSON(id: "r1"))}".utf8)
            )
        }

        _ = try await repo.update(id: "r1", patch: MeasurementReminderUpdate(enabled: false))

        let call = try #require(log.snapshot.first)
        #expect(call.method == "PATCH")
        #expect(call.path == "/api/measurement-reminders/r1")
    }

    @Test("delete DELETEs /api/measurement-reminders/{id} and tolerates the deleted envelope")
    func deleteRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":{\"deleted\":true}}".utf8)
            )
        }

        try await repo.delete(id: "r1")

        let call = try #require(log.snapshot.first)
        #expect(call.method == "DELETE")
        #expect(call.path == "/api/measurement-reminders/r1")
    }

    @Test("satisfy POSTs /api/measurement-reminders/{id}/satisfy and returns the re-anchored row")
    func satisfyRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            // Re-anchored row: lastSatisfiedAt now stamped, nextDueAt advanced.
            let payload = """
            {"data":{"id":"r1","label":"Annual blood test","measurementType":"WEIGHT",
             "intervalDays":30,"rrule":null,"anchorDate":null,"endsOn":null,"origin":"VORSORGE",
             "notifyHour":9,"location":null,"nextDueAt":"2026-08-01T09:00:00.000Z",
             "lastSatisfiedAt":"2026-07-02T09:00:00.000Z","enabled":true,
             "createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-07-02T09:00:00.000Z"}}
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }

        let updated = try await repo.satisfy(id: "r1")

        #expect(updated.lastSatisfiedAt != nil)
        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/measurement-reminders/r1/satisfy")
    }

    @Test("complete POSTs /api/measurement-reminders/{id}/complete and unwraps {completed,reminder}")
    func completeRoute() async throws {
        let repo = makeRepo()
        let log = RequestLog()
        MockURLProtocol.handler = { req in
            log.record(method: req.httpMethod ?? "?", path: req.url!.path)
            let payload = """
            {"data":{"completed":true,"reminder":{"id":"r1","label":"Annual blood test",
             "measurementType":"WEIGHT","intervalDays":30,"rrule":null,"anchorDate":null,
             "endsOn":null,"origin":"VORSORGE","notifyHour":9,"location":null,
             "nextDueAt":"2026-08-01T09:00:00.000Z","lastSatisfiedAt":"2026-07-02T09:00:00.000Z",
             "enabled":true,"createdAt":"2026-06-01T09:00:00.000Z","updatedAt":"2026-07-02T09:00:00.000Z"}}}
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }

        let result = try await repo.complete(id: "r1")

        #expect(result.completed == true)
        #expect(result.reminder.id == "r1")
        #expect(result.reminder.lastSatisfiedAt != nil)
        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/measurement-reminders/r1/complete")
    }

    @Test("complete tolerates the idempotent no-op (completed=false)")
    func completeIdempotentNoOp() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"completed":false,"reminder":{"id":"r1","label":"Annual blood test",
             "measurementType":"WEIGHT","intervalDays":30,"rrule":null,"anchorDate":null,
             "endsOn":null,"origin":"VORSORGE","notifyHour":9,"location":null,
             "nextDueAt":"2026-08-01T09:00:00.000Z","lastSatisfiedAt":"2026-07-02T09:00:00.000Z",
             "enabled":true}}}
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }

        let result = try await repo.complete(id: "r1")
        #expect(result.completed == false, "already-satisfied reminder returns a no-op")
        #expect(result.reminder.id == "r1")
    }
}

// MARK: - The accepted v1.37.20 surface (skip / snooze / history)

/// Kept as an extension of the suite above rather than inlined into it: the
/// v1.37.20 clauses are their own subject, and the original struct is already at
/// the repository's body-length budget.
extension MeasurementReminderRepositoryTests {
    // Every request shape and every response body below is the frozen contract
    // from Plan 08-18 — `HealthLogTests/Fixtures/Server/v1.37.20/`, extracted
    // from tag `3a2c0e75` — loaded through that plan's own fixture reader rather
    // than retyped here, so a second copy cannot drift from the accepted bytes.

    /// Everything about a request the accepted contract actually constrains:
    /// method, path, the query window, whether a body exists at all, and the two
    /// headers that follow from a body existing.
    private struct RecordedWireCall {
        let method: String
        let path: String
        let query: String?
        let body: Data?
        let contentType: String?
        let idempotencyKey: String?
    }

    /// Endpoint-scoped call log (CU-07): only reminder requests are recorded, so
    /// a suite running in parallel cannot add a row to this one's assertions.
    private final class WireLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [RecordedWireCall] = []

        func record(_ request: URLRequest) {
            guard request.targets(prefixedBy: "/api/measurement-reminders") else { return }
            let call = RecordedWireCall(
                method: request.httpMethod ?? "?",
                path: request.url?.path ?? "?",
                query: request.url?.query,
                body: MeasurementReminderRepositoryTests.bodyBytes(of: request),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key")
            )
            lock.lock()
            defer { lock.unlock() }
            entries.append(call)
        }

        var snapshot: [RecordedWireCall] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// `URLProtocol` moves `httpBody` onto `httpBodyStream`; re-materialize
    /// either. `nil` means the request genuinely carries no body — which is the
    /// whole point of the skip clause below, so the two cases must stay distinct
    /// from "an empty body".
    private nonisolated static func bodyBytes(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var accumulated = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            accumulated.append(buffer, count: read)
        }
        return accumulated
    }

    /// One frozen fixture payload, re-serialized to the bytes a server would send.
    private static func frozenBytes(_ scenario: String) throws -> Data {
        let object = try #require(MeasurementReminderV13720ContractTests.fixture()[scenario])
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func respond(_ req: URLRequest, _ status: Int, _ payload: Data) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, payload)
    }

    @Test("skip POSTs …/skip with NO body at all and unwraps {skipped, reminder}")
    func skipRouteSendsNoBody() async throws {
        let repo = makeRepo()
        let log = WireLog()
        let payload = try Self.frozenBytes("skipAppliedEnvelope")
        MockURLProtocol.handler = { req in
            log.record(req)
            return Self.respond(req, 200, payload)
        }

        let result = try await repo.skip(id: "rem_skipped_0003")

        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/measurement-reminders/rem_skipped_0003/skip")
        // The accepted route declares no `requestBody`. Absent is not `{}`:
        // satisfy/complete send two bytes and a JSON content type here, and this
        // one must send neither.
        #expect((call.body ?? Data()).isEmpty, "the accepted skip route declares no requestBody")
        #expect(call.contentType == nil, "a bodyless POST must not announce a JSON content type")
        // Idempotency is preserved: a manual retry after a network blip must not
        // record a second skip.
        #expect(call.idempotencyKey?.isEmpty == false)

        #expect(result.skipped)
        #expect(result.reminder.id == "rem_skipped_0003")
        #expect(result.reminder.skipCount == 3)
        #expect(result.reminder.lastSkippedAt != nil)
        #expect(result.reminder.snoozedUntil == nil, "a skip clears any snooze")
        #expect(
            result.reminder.lastSatisfiedAt == ISO8601DateFormatter().date(from: "2025-08-11T08:04:00Z"),
            "a skip never moves lastSatisfiedAt — it is not a completion"
        )
    }

    @Test("skip tolerates the idempotent forward-only no-op (skipped=false)")
    func skipIdempotentNoOp() async throws {
        let repo = makeRepo()
        let payload = try Self.frozenBytes("skipNoOpEnvelope")
        MockURLProtocol.handler = { req in Self.respond(req, 200, payload) }

        let result = try await repo.skip(id: "rem_skipped_0003")
        #expect(result.skipped == false, "a concurrent skip or satisfy already advanced the row")
        #expect(result.reminder.id == "rem_skipped_0003", "the canonical row still comes back")
    }

    @Test("snooze POSTs the exact {until} calendar-day body and unwraps {reminder}")
    func snoozeRouteSendsTheDayBody() async throws {
        let repo = makeRepo()
        let log = WireLog()
        let payload = try Self.frozenBytes("snoozeAppliedEnvelope")
        MockURLProtocol.handler = { req in
            log.record(req)
            return Self.respond(req, 200, payload)
        }

        let row = try await repo.snooze(id: "rem_snoozed_0002", until: "2026-08-24")

        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/measurement-reminders/rem_snoozed_0002/snooze")
        // Snooze declares `requestBody: required` — the opposite answer to skip's,
        // in the same contract.
        let body = try #require(call.body)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let parsed = try #require(decoded as? [String: Any])
        #expect(Set(parsed.keys) == ["until"], "the body publishes exactly one key")
        #expect(parsed["until"] as? String == "2026-08-24")
        #expect(call.contentType == "application/json")
        #expect(call.idempotencyKey?.isEmpty == false)

        #expect(row.id == "rem_snoozed_0002")
        #expect(row.snoozedUntil == ISO8601DateFormatter().date(from: "2026-08-24T06:00:00Z"))
        #expect(row.snoozedUntil == row.nextDueAt, "the server sets both to the same resolved instant")
        #expect(row.lastSkippedAt == nil)
        #expect(row.skipCount == 0)
    }

    @Test("the skip and snooze envelopes are not interchangeable")
    func envelopesAreNotInterchangeable() async throws {
        let repo = makeRepo()

        // A snooze body has no `skipped` flag, so it cannot answer a skip.
        let snoozeShaped = try Self.frozenBytes("snoozeAppliedEnvelope")
        MockURLProtocol.handler = { req in Self.respond(req, 200, snoozeShaped) }
        await #expect(throws: (any Error).self) {
            _ = try await repo.skip(id: "rem_snoozed_0002")
        }

        // And a bare reminder is not the snooze envelope: the accepted response
        // wraps the row in `{ reminder }`.
        let bareReminder = try Self.frozenBytes("reminderSnoozed")
        MockURLProtocol.handler = { req in Self.respond(req, 200, bareReminder) }
        await #expect(throws: (any Error).self) {
            _ = try await repo.snooze(id: "rem_snoozed_0002", until: "2026-08-24")
        }
    }

    @Test("history GETs …/history and decodes the page's own meta, newest first")
    func historyRoute() async throws {
        let repo = makeRepo()
        let log = WireLog()
        let payload = try Self.frozenBytes("historyFirstPage")
        MockURLProtocol.handler = { req in
            log.record(req)
            return Self.respond(req, 200, payload)
        }

        let page = try await repo.history(id: "rem_skipped_0003")

        let call = try #require(log.snapshot.first)
        #expect(call.method == "GET")
        #expect(call.path == "/api/measurement-reminders/rem_skipped_0003/history")
        #expect(call.query == nil, "an omitted window takes the published server defaults verbatim")

        // `data.meta`, not the transport's `meta.requestId` — two different keys
        // in one response.
        #expect(page.meta.total == 3)
        #expect(page.meta.limit == 50)
        #expect(page.meta.offset == 0)
        #expect(page.events.count == 3)
        #expect(page.events.map(\.occurredAt) == page.events.map(\.occurredAt).sorted(by: >))
        #expect(page.events.map(\.kind) == [.skipped, .satisfied, .satisfied])
        #expect(page.events.map(\.source) == [.skip, .manual, .encounter])
        #expect(page.events.map(\.onTime) == [false, true, false])
        #expect(page.events.map(\.id) == ["evt_0003", "evt_0002", "evt_0001"])
    }

    @Test("history sends the caller's window verbatim and never clamps it")
    func historyWindowIsVerbatim() async throws {
        let repo = makeRepo()
        let log = WireLog()
        let payload = try Self.frozenBytes("historyEmptyLedger")
        MockURLProtocol.handler = { req in
            log.record(req)
            return Self.respond(req, 200, payload)
        }

        _ = try await repo.history(id: "r1", limit: 25, offset: 50)
        let windowed = try #require(log.snapshot.first)
        #expect(windowed.query == "limit=25&offset=50")

        // Out of the published 1…100 bound. The contract gives that refusal to
        // the server (422); clamping here would hide it.
        MockURLProtocol.handler = { req in
            log.record(req)
            return Self.respond(req, 422, Data(#"{"data":null,"error":"limit out of range"}"#.utf8))
        }
        await #expect(throws: (any Error).self) {
            _ = try await repo.history(id: "r1", limit: 500)
        }
        let unclamped = try #require(log.snapshot.last)
        #expect(unclamped.query == "limit=500")
    }

    @Test("an empty ledger is an answer, not a failure")
    func historyEmptyLedger() async throws {
        let repo = makeRepo()
        let payload = try Self.frozenBytes("historyEmptyLedger")
        MockURLProtocol.handler = { req in Self.respond(req, 200, payload) }

        let page = try await repo.history(id: "rem_legacy_0004")
        #expect(page.events.isEmpty)
        #expect(page.meta.total == 0, "history begins at the release that introduced it")
    }

    @Test("an unknown future kind or source keeps the page and its raw value")
    func historyToleratesFutureEnumValues() async throws {
        let repo = makeRepo()
        let payload = Data("""
        {"data":{"events":[
          {"id":"evt_future","kind":"POSTPONED","occurredAt":"2026-08-15T11:20:00Z",
           "onTime":false,"source":"pharmacy_sync","createdAt":"2026-08-15T11:20:00Z"}],
         "meta":{"total":1,"limit":50,"offset":0}},"error":null}
        """.utf8)
        MockURLProtocol.handler = { req in Self.respond(req, 200, payload) }

        let page = try await repo.history(id: "r1")
        let event = try #require(page.events.first)
        #expect(event.kind == .unknown("POSTPONED"))
        #expect(event.source == .unknown("pharmacy_sync"))
        #expect(event.kind.wireValue == "POSTPONED", "the raw value survives for the reader")
        #expect(event.source.wireValue == "pharmacy_sync")
    }

    @Test("every published error status surfaces on all three v1.37.20 routes")
    func publishedErrorStatuses() async throws {
        let repo = makeRepo()
        for status in [401, 403, 404, 422] {
            MockURLProtocol.handler = { req in
                Self.respond(req, status, Data(#"{"data":null,"error":"refused"}"#.utf8))
            }
            await #expect(throws: (any Error).self) { _ = try await repo.skip(id: "r1") }
            await #expect(throws: (any Error).self) { _ = try await repo.snooze(id: "r1", until: "2026-08-24") }
            await #expect(throws: (any Error).self) { _ = try await repo.history(id: "r1") }
        }
    }

    @Test("a published 429 surfaces as the typed rate limit on all three routes")
    func publishedRateLimit() async throws {
        let repo = makeRepo()
        MockURLProtocol.handler = { req in
            Self.respond(req, 429, Data(#"{"data":null,"error":"rate limited"}"#.utf8))
        }
        await #expect(throws: HLError.rateLimited(retryAfter: nil)) { _ = try await repo.skip(id: "r1") }
        await #expect(throws: HLError.rateLimited(retryAfter: nil)) {
            _ = try await repo.snooze(id: "r1", until: "2026-08-24")
        }
        await #expect(throws: HLError.rateLimited(retryAfter: nil)) { _ = try await repo.history(id: "r1") }
    }

    @Test("satisfy and complete still POST an empty object body — unchanged by v1.37.20")
    func priorWriteRoutesKeepTheirEmptyBody() async throws {
        let repo = makeRepo()
        let log = WireLog()
        let row = Data("{\"data\":\(Self.rowJSON(id: "r1"))}".utf8)
        MockURLProtocol.handler = { req in
            log.record(req)
            let completion = Data("{\"data\":{\"completed\":true,\"reminder\":\(Self.rowJSON(id: "r1"))}}".utf8)
            return Self.respond(req, 200, req.url?.path.hasSuffix("/complete") == true ? completion : row)
        }

        _ = try await repo.satisfy(id: "r1")
        _ = try await repo.complete(id: "r1")

        for call in log.snapshot {
            let bytes = try #require(call.body)
            #expect(String(data: bytes, encoding: .utf8) == "{}")
            #expect(call.contentType == "application/json")
        }
        #expect(log.snapshot.count == 2)
    }
}

// swiftlint:enable force_unwrapping
