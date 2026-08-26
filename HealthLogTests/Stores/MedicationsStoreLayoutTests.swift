import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **W-B184 MED-1 — medications-list layout mutations.**
///
/// Locks the store-level `setListOrder` contract against the web
/// `PUT /api/medications/layout`: the optimistic order is applied to
/// `listLayout` immediately, the PUT carries `version: 1` + ONLY the changed
/// field (preserve-when-absent), and an over-long order is capped at the
/// server bound before it ever reaches the wire.
///
/// **08-05 restated the three presentation cases in place**, because the app
/// had gone from two presentations to one and the setter that used to choose
/// between them had become inert. **08-13 deleted that setter**, so its two
/// remaining cases had no subject left; they are replaced by the update path
/// they were standing in for — a stored legacy presentation is neutralised on
/// read and an order change never states one back. The retriable-failure
/// coverage 08-05 moved onto `setListOrder` is untouched, and `setListOrder`
/// is now the only layout write the app can perform at all.
@MainActor
@Suite("MedicationsStore — list layout (W-B184 MED-1)")
struct MedicationsStoreLayoutTests {
    /// Extracts the (Sendable) path + raw body of a layout PUT, or `nil` for a
    /// GET / non-layout request. Returns `Data` (not a parsed dict) so the
    /// value crosses actor isolation cleanly under strict concurrency.
    private nonisolated static func putRaw(from request: any Sendable) -> (path: String, body: Data)? {
        guard let req = request as? APIRequest<MedicationListLayout>,
              req.method == .put,
              let body = req.body else { return nil }
        return (req.path, body)
    }

    private nonisolated func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// **08-13 — the update path for an account that already stored a legacy
    /// presentation, asserted at the store rather than at the decoder.**
    ///
    /// This replaces the two cases that drove `setListView`. That setter is
    /// deleted, so "handing the inert setter its only value changes nothing"
    /// is no longer a statement anyone can make; what has to stay true is
    /// strictly stronger and is what a real installation actually walks. The
    /// store loads a layout the server wrote before this app had one
    /// presentation, the user then drags a medication into a new order, and
    /// three things must hold: the legacy literal is neutralised on the way in,
    /// the PUT the drag produces carries no presentation key at all, and the
    /// server's own stored value is therefore preserved rather than
    /// overwritten. No path in the app can express a presentation any more —
    /// `MedicationListLayoutPatch` has no field for one.
    @Test("A legacy stored presentation survives an order change untouched")
    func legacyLayoutSurvivesAnOrderWrite() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let captured = CapturedPut()
        await api.setHandler { request in
            if let put = Self.putRaw(from: request) {
                await captured.record(path: put.path, body: put.body)
                return MedicationListLayout(order: ["m2", "m1"])
            }
            // The GET answers exactly what an account upgraded from an older
            // build has on the server today.
            return try JSONDecoder().decode(
                MedicationListLayout.self,
                from: Data(#"{"version":1,"view":"table","order":["m1","m2"]}"#.utf8)
            )
        }

        await store.fetchListLayout()
        #expect(store.listLayout.view == .cards, "a legacy presentation literal must not restore a second presentation")
        #expect(store.listLayout.order == ["m1", "m2"], "neutralising it must not cost the saved order")

        let outcome = await store.setListOrder(["m2", "m1"])
        #expect(outcome == .success)

        let object = try json(#require(await captured.body))
        #expect(object["order"] as? [String] == ["m2", "m1"])
        #expect(
            object["view"] == nil,
            "an order change must not state a presentation, so the server keeps the one it has"
        )
        #expect(await captured.path == "/api/medications/layout")
    }

    @Test("setListOrder PUTs an order-only body + adopts the server echo")
    func setOrderPersists() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let captured = CapturedPut()
        await api.setHandler { request in
            if let put = Self.putRaw(from: request) {
                await captured.record(path: put.path, body: put.body)
            }
            return MedicationListLayout(view: .cards, order: ["m2", "m1"])
        }

        let outcome = await store.setListOrder(["m2", "m1"])

        #expect(outcome == .success)
        #expect(store.listLayout.order == ["m2", "m1"])
        let object = try json(#require(await captured.body))
        #expect(object["version"] as? Int == 1)
        #expect(object["order"] as? [String] == ["m2", "m1"])
        #expect(object["view"] == nil)
    }

    @Test("setListOrder caps an over-long order at the server bound before PUT")
    func setOrderCapsLargeList() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let captured = CapturedPut()
        await api.setHandler { request in
            if let put = Self.putRaw(from: request) {
                await captured.record(path: put.path, body: put.body)
            }
            // Realistic echo: the server returns the (already-capped) order the
            // client PUT, decoded straight from the request body.
            if let put = Self.putRaw(from: request),
               let obj = try? JSONSerialization.jsonObject(with: put.body) as? [String: Any],
               let order = obj["order"] as? [String]
            {
                return MedicationListLayout(view: .cards, order: order)
            }
            return MedicationListLayout(view: .cards, order: [])
        }

        let cap = MedicationListLayout.orderMaxEntries
        let oversized = (0 ..< (cap + 50)).map { "m\($0)" }
        _ = await store.setListOrder(oversized)

        // Optimistic in-memory order is capped too (server echoes the capped order).
        #expect(store.listLayout.order.count == cap)
        let object = try json(#require(await captured.body))
        let sent = try #require(object["order"] as? [String])
        #expect(sent.count == cap, "An over-long order must be capped before the wire")
        #expect(sent.first == "m0")
        #expect(sent.last == "m\(cap - 1)")
    }

    @Test("setListOrder with an empty order is handled (no crash, empty body field)")
    func setOrderEmpty() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        // Seed a non-empty order so clearing it is a real change that PUTs.
        store.listLayout = MedicationListLayout(view: .cards, order: ["a", "b"])

        let captured = CapturedPut()
        await api.setHandler { request in
            if let put = Self.putRaw(from: request) {
                await captured.record(path: put.path, body: put.body)
            }
            return MedicationListLayout(view: .cards, order: [])
        }

        let outcome = await store.setListOrder([])
        #expect(outcome == .success)
        #expect(store.listLayout.order.isEmpty)
        let object = try json(#require(await captured.body))
        #expect(object["order"] as? [String] == [])
    }

    /// The retriable-failure half of the old presentation case, restated on the
    /// write that still exists. Same contract: the optimistic value survives an
    /// offline failure because the Outbox will replay the PUT.
    @Test("setListOrder retriable failure keeps the optimistic order + queues")
    func setOrderRetriableQueues() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.offline }
        let outcome = await store.setListOrder(["m2", "m1"])

        #expect(outcome == .queued)
        // Optimistic order stays so the drag doesn't snap back while offline.
        #expect(store.listLayout.order == ["m2", "m1"])
    }
}

/// Test-only sendable capture box for the last layout PUT (raw body + path).
private actor CapturedPut {
    private(set) var path: String?
    private(set) var body: Data?
    func record(path: String, body: Data) {
        self.path = path
        self.body = body
    }
}

// swiftlint:enable force_unwrapping
