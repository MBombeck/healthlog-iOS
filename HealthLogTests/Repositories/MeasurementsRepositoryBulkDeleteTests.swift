import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.8 W3 — v1.15.13 adoption: `POST /api/measurements/bulk-delete`
/// (RESEARCH-SERVER-PARITY A2). Real `APIClient` over `MockURLProtocol`
/// (PROJECT_GUIDE.md: never a mock server on the outbox-replay path). Pins:
///
///   1. POST body `{ ids: [...] }` + `Idempotency-Key`, `{deleted}` decode.
///   2. >200-id selections chunk into ≤200-id POSTs, summing `deleted`.
///   3. Retriable failure → chunk(s) land on the outbox under
///      `bulkDeleteMeasurements`, error re-throws.
///   4. Non-retriable failure (422) → NOT enqueued.
///   5. Replay path re-POSTs under the persisted key.
@Suite("MeasurementsRepository — bulk delete", .serialized)
struct MeasurementsRepositoryBulkDeleteTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// Thread-safe request recorder (method + url + body + idempotency key).
    private final class Recorder: @unchecked Sendable {
        struct Entry {
            let url: URL
            let method: String?
            let idempotencyKey: String?
            let body: Data?
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []

        func record(_ req: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            _entries.append(Entry(
                url: req.url!,
                method: req.httpMethod,
                idempotencyKey: req.value(forHTTPHeaderField: "Idempotency-Key"),
                body: req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            ))
        }

        var entries: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return _entries
        }

        static func consumeStream(_ stream: InputStream) -> Data? {
            stream.open()
            defer { stream.close() }
            var buf = Data()
            var raw = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&raw, maxLength: 4096)
                guard read > 0 else { break }
                buf.append(raw, count: read)
            }
            return buf.isEmpty ? nil : buf
        }
    }

    private static func bodyIDs(_ body: Data?) throws -> [String] {
        let obj = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        return try #require(obj["ids"] as? [String])
    }

    @Test("POST carries {ids} + Idempotency-Key and decodes {deleted}")
    func postBodyAndDecode() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let data = Data(#"{"data":{"deleted":3}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let deleted = try await repo.bulkDelete(ids: ["a", "b", "c"])
        #expect(deleted == 3)
        let entry = try #require(recorder.entries.first)
        #expect(entry.method == "POST")
        #expect(entry.url.path == "/api/measurements/bulk-delete")
        #expect(entry.idempotencyKey?.isEmpty == false)
        #expect(try Self.bodyIDs(entry.body) == ["a", "b", "c"])
    }

    @Test("a 250-id selection chunks into 200 + 50 and sums deleted")
    func chunksLargeSelections() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = req.httpBody ?? Recorder.consumeStream(req.httpBodyStream!)
            let obj = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            let count = (obj?["ids"] as? [String])?.count ?? 0
            let data = Data("{\"data\":{\"deleted\":\(count)}}".utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let ids = (0 ..< 250).map { "m-\($0)" }
        let deleted = try await repo.bulkDelete(ids: ids)
        #expect(deleted == 250)
        let posts = recorder.entries.filter { $0.method == "POST" }
        #expect(posts.count == 2)
        #expect(try Self.bodyIDs(posts[0].body).count == 200)
        #expect(try Self.bodyIDs(posts[1].body).count == 50)
        // Each chunk carries its OWN idempotency key.
        #expect(posts[0].idempotencyKey != posts[1].idempotencyKey)
    }

    @Test("retriable failure enqueues the chunk for replay and re-throws")
    func retriableEnqueues() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"error":"upstream down"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        await #expect(throws: HLError.self) {
            try await repo.bulkDelete(ids: ["a", "b"])
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .bulkDeleteMeasurements)
        let payload = try #require(snap.first?.payload)
        let decoded = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.BulkDeleteMeasurements.self,
            from: payload
        )
        #expect(decoded.ids == ["a", "b"])
    }

    @Test("non-retriable failure (422) is NOT enqueued")
    func nonRetriableNotEnqueued() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"error":"Validation failed"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        await #expect(throws: HLError.self) {
            try await repo.bulkDelete(ids: ["a"])
        }
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "422 is non-retriable — nothing should land on the outbox")
    }

    @Test("replay re-POSTs the chunk under the persisted idempotency key")
    func replayUsesPersistedKey() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let data = Data(#"{"data":{"deleted":2}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let deleted = try await repo.replayBulkDelete(ids: ["a", "b"], idempotencyKey: "persisted-key-123")
        #expect(deleted == 2)
        let entry = try #require(recorder.entries.first)
        #expect(entry.idempotencyKey == "persisted-key-123")
        #expect(try Self.bodyIDs(entry.body) == ["a", "b"])
    }
}

/// v0.14.8 W3 — store-level optimistic semantics for the bulk delete.
@MainActor
@Suite("MeasurementsStore — bulk delete", .serialized)
struct MeasurementsStoreBulkDeleteTests {
    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private nonisolated static func response(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Seed `store.recent` with two WEIGHT rows via the real `load()` path.
    private func seedTwoWeights(store: MeasurementsStore) async {
        MockURLProtocol.handler = { req in
            if req.url?.path.contains("/series") == true {
                return (Self.response(200, request: req), Data(#"{"data":{"points":[]}}"#.utf8))
            }
            let body = """
            {"data":{"measurements":[\
            {"id":"m-1","type":"WEIGHT","value":72.4,"measuredAt":"2023-11-14T22:13:20Z"},\
            {"id":"m-2","type":"WEIGHT","value":72.9,"measuredAt":"2023-11-13T22:13:20Z"}]}}
            """
            return (Self.response(200, request: req), Data(body.utf8))
        }
        await store.load()
    }

    @Test("bulk delete removes the rows optimistically and POSTs once")
    func bulkDeleteOptimistic() async throws {
        let api = makeAPI()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        await seedTwoWeights(store: store)
        let targets = store.recent.filter { ["m-1", "m-2"].contains($0.id) }
        #expect(targets.count == 2)

        MockURLProtocol.handler = { req in
            (Self.response(200, request: req), Data(#"{"data":{"deleted":2}}"#.utf8))
        }
        let ok = await store.bulkDelete(targets)
        #expect(ok)
        #expect(store.recent.isEmpty, "Both rows must leave recent optimistically and stay gone")
        #expect(store.error == nil)
    }

    @Test("non-retriable failure rolls the optimistic removal back")
    func bulkDeleteRollsBackOnNonRetriable() async throws {
        let api = makeAPI()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        await seedTwoWeights(store: store)
        let targets = store.recent

        MockURLProtocol.handler = { req in
            (Self.response(422, request: req), Data(#"{"error":"Validation failed"}"#.utf8))
        }
        let ok = await store.bulkDelete(targets)
        #expect(!ok)
        #expect(store.recent.count == 2, "Non-retriable failure must restore the rows")
        #expect(store.error != nil)
    }

    @Test("BP rows include the diastolic peer id in the delete set")
    func bulkDeleteIncludesBPPeer() async throws {
        let api = makeAPI()
        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MeasurementsStore(repo: repo)
        let bp = Measurement(
            id: "sys-1",
            kind: .bloodPressure,
            recordedAt: .now,
            value: .bloodPressure(systolic: 124, diastolic: 82),
            note: nil,
            source: .manual,
            externalUUID: nil,
            bloodPressureDiastolicId: "dia-1"
        )
        let recordedIDs = LockedBox()
        MockURLProtocol.handler = { req in
            let body = req.httpBody ?? req.httpBodyStream.flatMap { stream -> Data? in
                stream.open()
                defer { stream.close() }
                var buf = Data()
                var raw = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&raw, maxLength: 4096)
                    guard read > 0 else { break }
                    buf.append(raw, count: read)
                }
                return buf
            }
            if let body,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let ids = obj["ids"] as? [String]
            {
                recordedIDs.set(ids)
            }
            return (Self.response(200, request: req), Data(#"{"data":{"deleted":2}}"#.utf8))
        }
        let ok = await store.bulkDelete([bp])
        #expect(ok)
        #expect(recordedIDs.get() == ["sys-1", "dia-1"], "the DIA half must ride along or it resurfaces solo")
    }

    /// Minimal thread-safe box for the handler → test handoff.
    private final class LockedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func set(_ value: [String]) {
            lock.lock()
            defer { lock.unlock() }
            ids = value
        }

        func get() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }
}

// swiftlint:enable force_unwrapping
