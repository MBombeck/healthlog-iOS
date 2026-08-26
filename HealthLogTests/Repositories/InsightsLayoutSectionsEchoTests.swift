import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-B184 #19 — the verbatim-section echo workaround is RETIRED. Server
/// v1.16.13/1.16.14 (`serializeInsightsLayout`, GH #19) now MERGE-preserves the
/// stored `sections` on a PUT that omits the field, so iOS no longer needs to
/// re-send the GET's sections on every tiles-only write. These tests pin the
/// new no-echo contract end-to-end against the real `APIClient` + encoder
/// (PROJECT_GUIDE.md rule: no mock-server for outbox/replay paths):
///
///   1. A sections-LESS layout (legacy cache / old outbox payload) is written
///      WITHOUT a `sections` key and WITHOUT a defensive donor GET.
///   2. A PUT after a GET still round-trips the sections it already carries
///      (harmless — the model holds them); the workaround backfill is gone.
///   3. Store reorder + toggle keep the tiles edit on the wire.
///   4. A retriable failure of a sections-less write enqueues a sections-less
///      payload for replay (no echo).
@Suite("InsightsLayout v2 — sections (server-merge, no echo) #19", .serialized)
struct InsightsLayoutSectionsEchoTests {
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

    /// Thread-safe recorder of every request method + the last PUT body.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastPutBody: Data?
        private var _methods: [String] = []

        func record(_ req: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            _methods.append(req.httpMethod ?? "")
            guard req.httpMethod == "PUT" else { return }
            _lastPutBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
        }

        var lastPutBody: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _lastPutBody
        }

        var methods: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _methods
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

    /// Realistic v1.16.3 GET body: version 2, shuffled sections with mixed
    /// visibility (the operator's WEB customization) + the tiles.
    private static let v2GETBody = """
    { "data": { "version": 2,
      "sections": [
        { "id": "trends", "visible": true, "order": 0 },
        { "id": "wellness-scores", "visible": false, "order": 1 },
        { "id": "vitals", "visible": true, "order": 2 },
        { "id": "daily-briefing", "visible": false, "order": 3 },
        { "id": "period-review", "visible": true, "order": 4 },
        { "id": "cycle-summary", "visible": false, "order": 5 },
        { "id": "signals", "visible": true, "order": 6 },
        { "id": "rhythm-events", "visible": true, "order": 7 }
      ],
      "tiles": [
        { "id": "weight", "visible": true, "order": 0 },
        { "id": "pulse", "visible": true, "order": 1 }
      ] } }
    """

    private static func expectedSections() throws -> NSArray {
        let data = try #require(v2GETBody.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(root["data"] as? [String: Any])
        return try #require(envelope["sections"] as? NSArray)
    }

    private static func putRoot(of body: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// GET → the v2 fixture; PUT → echo the request body back.
    private static func installEchoHandler(_ recorder: Recorder) throws {
        let getData = try #require(v2GETBody.data(using: .utf8))
        MockURLProtocol.handler = { req in
            recorder.record(req)
            if req.httpMethod == "GET" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, getData)
            }
            let put = req.httpBody ?? req.httpBodyStream.flatMap(Recorder.consumeStream)
            let obj = try JSONSerialization.jsonObject(with: put ?? Data())
            let data = try JSONSerialization.data(withJSONObject: ["data": obj])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "hl.test.insightsLayoutSections.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Tests

    @Test("sections-less PUT omits sections AND issues no defensive donor GET")
    func sectionsLessPutSendsNoSectionsNoDonorGET() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        try Self.installEchoHandler(recorder)
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        // No prior fetch — e.g. an old outbox payload or a legacy v1 cache.
        let legacy = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0)
        ])
        _ = try await repo.update(legacy)
        let putBody = try #require(recorder.lastPutBody)
        let root = try Self.putRoot(of: putBody)
        #expect(root["sections"] == nil, "server merge-preserves stored sections; iOS sends none")
        // The workaround's defensive donor GET is gone — only the PUT hit the wire.
        #expect(!recorder.methods.contains("GET"), "no donor GET for a sections-less write")
        #expect(recorder.methods.filter { $0 == "PUT" }.count == 1)
    }

    @Test("PUT after a GET still round-trips the sections the layout carries")
    func putRoundTripsCarriedSections() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        try Self.installEchoHandler(recorder)
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        // The store's real flow: GET, then a tiles-only mutation, then PUT.
        let fetched = try await repo.fetch()
        let edited = fetched.reordering([InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
        _ = try await repo.update(edited)
        let putBody = try #require(recorder.lastPutBody)
        let putRoot = try Self.putRoot(of: putBody)
        // The carried sections still serialize (harmless round-trip, not echo-backfill).
        let emitted = try #require(putRoot["sections"] as? NSArray)
        let expected = try Self.expectedSections()
        #expect(emitted == expected)
        // And the tiles edit itself made it onto the wire, on the v2 version.
        let tiles = try #require(putRoot["tiles"] as? [[String: Any]])
        #expect(tiles.map { $0["id"] as? String } == [InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
        #expect(putRoot["version"] as? Int == 2)
    }

    @Test("store reorder + toggle write the tiles edit on every PUT")
    @MainActor
    func storeMutationsWriteTiles() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        try Self.installEchoHandler(recorder)
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let defaults = Self.scratchDefaults()
        let store = InsightsLayoutStore(repo: repo, defaults: defaults)
        await store.load()
        await store.reorder([InsightsLayoutTileId.pulse, InsightsLayoutTileId.weight])
        #expect(store.error == nil)
        let reorderBody = try #require(recorder.lastPutBody)
        let reorderRoot = try Self.putRoot(of: reorderBody)
        let reorderTiles = try #require(reorderRoot["tiles"] as? [[String: Any]])
        #expect(reorderTiles.first?["id"] as? String == InsightsLayoutTileId.pulse)
        await store.toggleVisible(forId: InsightsLayoutTileId.weight)
        #expect(store.error == nil)
        #expect(recorder.lastPutBody != nil)
    }

    @Test("retriable failure of a sections-less write enqueues a sections-less payload")
    func retriableEnqueuesWithoutSectionsEcho() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let failBody = try JSONSerialization.data(withJSONObject: ["error": "upstream down"])
        MockURLProtocol.handler = { req in
            // Every method 503s — a sections-less write must NOT first reach for a GET.
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, failBody)
        }
        let repo = InsightsLayoutRepository(api: api, outbox: outbox)
        let legacy = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0)
        ])
        await #expect(throws: HLError.self) {
            try await repo.update(legacy.togglingVisibility(forId: InsightsLayoutTileId.weight))
        }
        let snap = await outbox.snapshot
        #expect(snap.count == 1)
        let payload = try #require(snap.first?.payload)
        let decoded = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.UpdateInsightsLayout.self, from: payload)
        #expect(decoded.layout.sections == nil, "replay payload carries no sections echo — server merges them")
    }

    // MARK: - Parity Build 4 · 4.5 — iOS now EDITS sections

    @Test("store section reorder reaches the wire, defaults-merged")
    @MainActor
    func storeSectionReorderWritesSections() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        try Self.installEchoHandler(recorder)
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        await store.load()
        // The GET fixture carries only the ORIGINAL eight sections; the resolver
        // merges in the four the server has added since, so the editor and the
        // PUT both speak the current catalogue.
        #expect(store.sections.count == InsightsLayoutSectionId.allInDefaultOrder.count)

        await store.reorderSections([InsightsLayoutSectionId.labsChanges, InsightsLayoutSectionId.trends])
        #expect(store.error == nil)
        let body = try #require(recorder.lastPutBody)
        let root = try Self.putRoot(of: body)
        let sections = try #require(root["sections"] as? [[String: Any]])
        #expect(sections.first?["id"] as? String == InsightsLayoutSectionId.labsChanges)
        #expect(sections.dropFirst().first?["id"] as? String == InsightsLayoutSectionId.trends)
        #expect(store.sections.first?.id == InsightsLayoutSectionId.labsChanges)
    }

    @Test("store section hide reaches the wire and survives the echo")
    @MainActor
    func storeSectionToggleWritesVisibility() async throws {
        let api = makeAPI()
        let recorder = Recorder()
        try Self.installEchoHandler(recorder)
        let repo = try InsightsLayoutRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = InsightsLayoutStore(repo: repo, defaults: Self.scratchDefaults())
        await store.load()
        // `vitals` is visible in the fixture; hiding it must both reach the wire
        // and stick after the server echo replaces the optimistic layout.
        #expect(store.layout.isSectionVisible(InsightsLayoutSectionId.vitals))
        await store.toggleSectionVisible(forId: InsightsLayoutSectionId.vitals)
        #expect(store.error == nil)
        let body = try #require(recorder.lastPutBody)
        let root = try Self.putRoot(of: body)
        let sections = try #require(root["sections"] as? [[String: Any]])
        let vitals = try #require(sections.first { $0["id"] as? String == InsightsLayoutSectionId.vitals })
        #expect(vitals["visible"] as? Bool == false)
        #expect(!store.layout.visibleSectionIds.contains(InsightsLayoutSectionId.vitals))
    }
}
