import Foundation

// swiftlint:disable force_unwrapping force_try
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// SP3 + SP4 (v0.12) — server round-trip for the GLP-1 side-effect logbook and
/// pen/vial inventory. These tests use the **real `APIClient` over a stubbed
/// `URLSession`** (`MockURLProtocol`), per PROJECT_GUIDE.md — never a mock server — so
/// the Outbox-replay path is exercised against the exact server wire shape and
/// any schema drift is caught.
///
/// Coverage:
///   - DTO decodes the real `{ data: … }`-enveloped server shapes,
///   - optimistic write + Outbox enqueue on a retriable failure,
///   - the persisted idempotency-key is reused on replay (server dedup intact),
///   - replay clears the Outbox on 2xx,
///   - standalone (no server repo wired) performs zero server writes.
@Suite("MedicationTherapyLogRepository (SP3 + SP4)", .serialized)
struct MedicationTherapyLogRepositoryTests {
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

    private final class KeyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String] = []
        func record(_ key: String?) {
            guard let key else { return }
            lock.lock()
            defer { lock.unlock() }
            keys.append(key)
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return keys
        }
    }

    private final class Phase: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ new: Int) {
            lock.lock()
            defer { lock.unlock() }
            value = new
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// The real POST 201 body the side-effects route returns (apiSuccess(row, 201)).
    /// (Wire-identical to the one-line server payload — JSON ignores the
    /// inter-token newlines introduced for the 240-char line budget.)
    private let sideEffectRowJSON = #"""
    {"data":{
      "id":"se-1","userId":"u-1","medicationId":"med-1",
      "category":"GI","entry":"NAUSEA","severity":3,
      "occurredAt":"2026-05-01T08:00:00Z","notes":"after breakfast",
      "createdAt":"2026-05-01T08:00:01Z","updatedAt":"2026-05-01T08:00:01Z"}}
    """#

    /// The real GET list body (apiSuccess({ items, meta })).
    private let sideEffectListJSON = #"""
    {"data":{"items":[{
      "id":"se-1","userId":"u-1","medicationId":"med-1",
      "category":"GI","entry":"NAUSEA","severity":3,
      "occurredAt":"2026-05-01T08:00:00Z","notes":null,
      "createdAt":"2026-05-01T08:00:01Z","updatedAt":"2026-05-01T08:00:01Z"}],
      "meta":{"total":1}}}
    """#

    /// The real inventory POST 201 body.
    private let inventoryRowJSON = #"""
    {"data":{
      "id":"inv-1","userId":"u-1","medicationId":"med-1","state":"ACTIVE",
      "unitsTotal":4,"unitsRemaining":4,"containerType":"PEN","firstUseAt":null,
      "printedExpiry":null,"expiresAt":null,"purchasedAt":"2026-05-01T00:00:00Z",
      "notes":null,"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z"}}
    """#

    // MARK: - DTO decode (real wire shapes)

    @Test("Side-effect row decodes the real enveloped server shape")
    func sideEffectDTODecodes() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationTherapyLogRepository(api: api, outbox: outbox)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(sideEffectListJSON.utf8)
            )
        }
        let rows = try await repo.sideEffects(medicationID: "med-1")
        #expect(rows.count == 1)
        #expect(rows.first?.entry == "NAUSEA")
        #expect(rows.first?.category == "GI")
        #expect(rows.first?.severity == 3)
    }

    @Test("Inventory row decodes the real enveloped server shape + state enum")
    func inventoryDTODecodes() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationTherapyLogRepository(api: api, outbox: outbox)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(inventoryRowJSON.utf8)
            )
        }
        let created = try await repo.createInventoryItem(
            medicationID: "med-1",
            body: MedicationInventoryCreate(unitsTotal: 4, printedExpiry: nil, purchasedAt: nil, notes: nil)
        )
        #expect(created.id == "inv-1")
        #expect(created.state == "ACTIVE")
        #expect(created.unitsTotal == 4)
        #expect(created.containerType == .pen)
    }

    // MARK: - Optimistic write + Outbox enqueue + replay (SP3)

    @Test("Side-effect create: retriable failure enqueues + replay reuses the key")
    func sideEffectOutboxReplayUsesOriginalKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationTherapyLogRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let phase = Phase()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if phase.current == 0 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(sideEffectRowJSON.utf8)
            )
        }

        let body = MedicationSideEffectCreate(
            entry: "NAUSEA",
            severity: 3,
            occurredAt: Date(timeIntervalSince1970: 1_714_550_400),
            notes: nil
        )

        await #expect(throws: HLError.self) {
            _ = try await repo.createSideEffect(medicationID: "med-1", body: body)
        }
        let queued = await outbox.snapshot
        #expect(queued.count == 1, "retriable failure must enqueue")
        #expect(queued.first?.kind == .createMedicationSideEffect)
        let firstKeys = recorder.snapshot
        #expect(Set(firstKeys).count == 1, "initial attempts share one key, got \(firstKeys)")
        #expect(queued.first?.idempotencyKey == firstKeys.first, "outbox persists the attempted key")

        phase.set(1)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            therapyLogRepo: repo,
            maxAttempts: 8
        )
        await replay.runOnce()

        let allKeys = recorder.snapshot
        #expect(Set(allKeys).count == 1, "replay reuses the original key, got \(allKeys)")
        await #expect(outbox.snapshot.isEmpty, "successful replay clears the outbox")
    }

    // MARK: - Optimistic write + Outbox enqueue + replay (SP4)

    @Test("Inventory create: retriable failure enqueues + replay reuses the key")
    func inventoryOutboxReplayUsesOriginalKey() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationTherapyLogRepository(api: api, outbox: outbox)

        let recorder = KeyRecorder()
        let phase = Phase()
        MockURLProtocol.handler = { req in
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if phase.current == 0 {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(inventoryRowJSON.utf8)
            )
        }

        let body = MedicationInventoryCreate(unitsTotal: 4, printedExpiry: nil, purchasedAt: nil, notes: nil)

        await #expect(throws: HLError.self) {
            _ = try await repo.createInventoryItem(medicationID: "med-1", body: body)
        }
        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createMedicationInventory)

        phase.set(1)
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            therapyLogRepo: repo,
            maxAttempts: 8
        )
        await replay.runOnce()

        let allKeys = recorder.snapshot
        #expect(Set(allKeys).count == 1, "replay reuses the original key")
        await #expect(outbox.snapshot.isEmpty)
    }

    // MARK: - Standalone = no server write

    @Test("Standalone: SideEffectsLogbookStore logs locally with zero server hits")
    @MainActor
    func standaloneSideEffectNoServerWrite() async throws {
        let hits = Counter()
        MockURLProtocol.handler = { req in
            _ = hits.increment()
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        let local = try GLP1LocalRepository(store: GLP1LocalStore(modelContainer: GLP1LocalStore.makeInMemory()))
        // serverRepo == nil → standalone branch: no network.
        let store = SideEffectsLogbookStore(medicationID: "med-1", repo: local, serverRepo: nil)
        await store.log(loggedAt: .now, kind: .nausea, severity: 2, note: nil)
        await store.load()
        // `Counter.count` is an Int hit-counter, not a Collection — no `isEmpty` exists.
        // swiftlint:disable:next empty_count
        #expect(hits.count == 0, "standalone must not touch the network")
        #expect(store.entries.count == 1, "the local row is still written + readable")
    }

    @Test("Standalone: PenInventoryStore adds locally with zero server hits")
    @MainActor
    func standaloneInventoryNoServerWrite() async throws {
        let hits = Counter()
        MockURLProtocol.handler = { req in
            _ = hits.increment()
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }
        let local = try GLP1LocalRepository(store: GLP1LocalStore(modelContainer: GLP1LocalStore.makeInMemory()))
        let store = PenInventoryStore(medicationID: "med-1", repo: local, serverRepo: nil)
        await store.add(manufacturer: "Lilly", doseStrength: "2.5 mg", dispensedAt: .now, firstUsedAt: nil, notes: nil)
        await store.load()
        // `Counter.count` is an Int hit-counter, not a Collection — no `isEmpty` exists.
        // swiftlint:disable:next empty_count
        #expect(hits.count == 0, "standalone must not touch the network")
        #expect(store.pens.count == 1)
    }
}
