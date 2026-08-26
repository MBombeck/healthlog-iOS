import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.0 W10 — coverage for `InsightsLayoutRepository` + `InsightsLayoutStore`
/// against a real `APIClient` with a stubbed `URLProtocol` (per the PROJECT_GUIDE.md
/// rule: never a mock-server for outbox/replay paths — schema-drift bugs only
/// surface against the real client + encoder).
///
/// Axes:
///   1. GET decodes the `{ tiles: [...] }` wire shape (reconciled).
///   2. PUT sends the full layout body + reflects the server echo.
///   3. DELETE resets to the server default echo.
///   4. 422 unknown-id → non-retriable, NOT enqueued, re-throws.
///   5. Retriable network failure → enqueued on the outbox, error re-thrown.
///   6. Store-level optimistic write + rollback on failure.
@Suite("InsightsLayoutRepository — server-first layout", .serialized)
struct InsightsLayoutRepositoryTests {
    // MARK: - Helpers

    private func makeAPI() -> APIClient {
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

    /// Records the last write request so a test can assert on body + method.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastMethod: String?
        private var _lastBody: Data?
        private var _putCount = 0
        private var _deleteCount = 0

        func record(_ req: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            _lastMethod = req.httpMethod
            if req.httpMethod == "PUT" { _putCount += 1 }
            if req.httpMethod == "DELETE" { _deleteCount += 1 }
            _lastBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
        }

        var lastMethod: String? {
            lock.lock()
            defer { lock.unlock() }
            return _lastMethod
        }

        var lastBody: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _lastBody
        }

        var putCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _putCount
        }

        var deleteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _deleteCount
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

    private func envelope(_ layout: InsightsLayout) throws -> Data {
        let inner = try JSONEncoder.hlDefault.encode(layout)
        let innerObj = try JSONSerialization.jsonObject(with: inner)
        return try JSONSerialization.data(withJSONObject: ["data": innerObj])
    }

    // MARK: - GET

    @Test("fetch decodes the {tiles:[...]} wire shape, reconciled")
    func fetchDecodes() async throws {
        let api = makeAPI()
        let server = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: false, order: 1)
        ])
        let data = try envelope(server)
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/insights/layout")
            #expect(req.httpMethod == "GET")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let got = try await repo.fetch()
        #expect(got.orderedTiles.map(\.id) == [InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse])
        #expect(got.tiles.first(where: { $0.id == InsightsLayoutTileId.pulse })?.visible == false)
    }

    // MARK: - PUT

    @Test("update sends the full layout body and reflects the server echo")
    func updateSendsBody() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        let toSave = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: false, order: 1)
        ])
        let echoData = try envelope(toSave)
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echoData)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let saved = try await repo.update(toSave)
        #expect(recorder.lastMethod == "PUT")
        #expect(recorder.putCount == 1)
        let lastBody = try #require(recorder.lastBody)
        let body = try #require(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
        let tiles = try #require(body["tiles"] as? [[String: Any]])
        #expect(tiles.count == 2)
        #expect(tiles.first?["id"] as? String == InsightsLayoutTileId.pulse)
        #expect(saved.orderedTiles.map(\.id) == [InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
    }

    // MARK: - DELETE

    @Test("reset DELETEs and returns the server default echo")
    func resetDeletes() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        let echoData = try envelope(.default)
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echoData)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let reset = try await repo.reset()
        #expect(recorder.lastMethod == "DELETE")
        #expect(recorder.deleteCount == 1)
        #expect(reset == .default)
    }

    // MARK: - 422 unknown-id

    @Test("422 unknown-id is non-retriable and is NOT enqueued")
    func unknownIdNotEnqueued() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let body = try JSONSerialization.data(withJSONObject: ["error": "unknown tile id", "errorCode": "invalid_tile"])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = InsightsLayoutRepository(api: api, outbox: outbox)
        let bad = InsightsLayout(tiles: [InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0)])
        await #expect(throws: HLError.self) {
            try await repo.update(bad)
        }
        let snap = await outbox.snapshot
        #expect(snap.isEmpty, "422 is non-retriable — nothing should land on the outbox")
    }

    // MARK: - Retriable → outbox

    @Test("retriable server error enqueues the layout for replay and re-throws")
    func retriableEnqueues() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let body = try JSONSerialization.data(withJSONObject: ["error": "upstream down"])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = InsightsLayoutRepository(api: api, outbox: outbox)
        let toSave = InsightsLayout(tiles: [InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: true, order: 0)])
        await #expect(throws: HLError.self) {
            try await repo.update(toSave)
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        #expect(snap.first?.kind == .updateInsightsLayout)
    }

    // MARK: - Store optimistic + rollback

    @Test("store reorder optimistically updates, then keeps the server echo")
    @MainActor
    func storeOptimisticSuccess() async throws {
        let api = makeAPI()
        // Echo whatever the client PUTs.
        MockURLProtocol.handler = { req in
            guard let put = req.httpBody ?? req.httpBodyStream.flatMap(Recorder.consumeStream) else {
                throw HLError.unknown("missing PUT body")
            }
            let obj = try JSONSerialization.jsonObject(with: put)
            let data = try JSONSerialization.data(withJSONObject: ["data": obj])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        // Seed a known starting layout.
        let start = ["a", InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse]
        await store.reorder(start) // server echoes filtered (a dropped) but order known ids persists
        let newOrder = [InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight]
        await store.reorder(newOrder)
        #expect(store.error == nil)
        #expect(store.layout.orderedTiles.map(\.id).prefix(2) == [InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
    }

    @Test("store reorder rolls back on a non-retriable failure")
    @MainActor
    func storeRollbackOnFailure() async throws {
        let api = makeAPI()
        let body = try JSONSerialization.data(withJSONObject: ["error": "bad"])
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        let before = store.layout
        await store.reorder([InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
        #expect(store.error != nil)
        #expect(store.layout == before, "failed PUT must roll the optimistic order back")
    }

    @Test("store toggleVisible optimistically flips the tile and persists")
    @MainActor
    func storeToggleVisible() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            guard let put = req.httpBody ?? req.httpBodyStream.flatMap(Recorder.consumeStream) else {
                throw HLError.unknown("missing PUT body")
            }
            let obj = try JSONSerialization.jsonObject(with: put)
            let data = try JSONSerialization.data(withJSONObject: ["data": obj])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        // gewicht starts visible in the default layout.
        let before = store.layout.tiles.first { $0.id == InsightsLayoutTileId.weight }?.visible
        #expect(before == true)
        await store.toggleVisible(forId: InsightsLayoutTileId.weight)
        #expect(store.error == nil)
        #expect(store.layout.tiles.first { $0.id == InsightsLayoutTileId.weight }?.visible == false)
    }

    @Test("store resetToDefaults DELETEs and adopts the server echo")
    @MainActor
    func storeReset() async throws {
        let api = makeAPI()
        let echoData = try envelope(.default)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echoData)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        await store.resetToDefaults()
        #expect(store.error == nil)
        #expect(store.layout == .default)
    }

    // MARK: - v0.8.1 WB — add-tile re-enable + intra-mood-pair order

    @Test("add-tile flow re-enables a hidden tile via the store toggle")
    @MainActor
    func storeAddTileReEnablesHidden() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            guard let put = req.httpBody ?? req.httpBodyStream.flatMap(Recorder.consumeStream) else {
                throw HLError.unknown("missing PUT body")
            }
            let obj = try JSONSerialization.jsonObject(with: put)
            let data = try JSONSerialization.data(withJSONObject: ["data": obj])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        // schlaf starts HIDDEN in the default layout (the add-tile "+" sheet
        // would list it). Re-adding flips it visible through the same toggle.
        #expect(store.layout.tiles.first { $0.id == InsightsLayoutTileId.sleep }?.visible == false)
        await store.toggleVisible(forId: InsightsLayoutTileId.sleep)
        #expect(store.error == nil)
        #expect(store.layout.tiles.first { $0.id == InsightsLayoutTileId.sleep }?.visible == true)
    }

    @Test("setMoodHalfOrder persists the intra-pair order and filters strays")
    @MainActor
    func storeMoodHalfOrderPersists() throws {
        let api = makeAPI()
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let defaults = Self.scratchDefaults()
        let store = InsightsLayoutStore(repo: repo, defaults: defaults)
        // Default is empty (→ falls back to score-then-stability in the grid).
        #expect(store.moodHalfOrder.isEmpty)
        // Drag stability before score; a stray id is filtered out.
        store.setMoodHalfOrder(["MOOD_STABILITY", "WEIGHT", "MOOD_SCORE"])
        #expect(store.moodHalfOrder == ["MOOD_STABILITY", "MOOD_SCORE"])
        // A fresh store over the SAME defaults reads the persisted order.
        let reloaded = InsightsLayoutStore(repo: repo, defaults: defaults)
        #expect(reloaded.moodHalfOrder == ["MOOD_STABILITY", "MOOD_SCORE"])
    }

    @Test("clearOnLogout wipes the persisted intra-mood-pair order")
    @MainActor
    func storeMoodHalfOrderClearedOnLogout() throws {
        let api = makeAPI()
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let defaults = Self.scratchDefaults()
        let store = InsightsLayoutStore(repo: repo, defaults: defaults)
        store.setMoodHalfOrder(["MOOD_STABILITY", "MOOD_SCORE"])
        store.clearOnLogout()
        #expect(store.moodHalfOrder.isEmpty)
        let reloaded = InsightsLayoutStore(repo: repo, defaults: defaults)
        #expect(reloaded.moodHalfOrder.isEmpty)
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "hl.test.insightsLayout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
