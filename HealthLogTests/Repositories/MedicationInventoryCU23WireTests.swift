import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-23 — inventory wire behaviour, asserted on the body that actually goes out.**
///
/// Real `APIClient` over `MockURLProtocol` (never a mock server), so the
/// tri-state PATCH is verified against the bytes on the wire rather than against
/// the Swift value that produced them:
///   - `markAsFirstUseAt` accepts `null` to DELETE the opening date (A7). An
///     omitted key and an explicit `null` mean different things to the route,
///     which is exactly the trap `RecordPatchField` exists to close.
///   - the same tri-state now drives `printedExpiry` (M-1), replacing the
///     ad-hoc clear-flag.
///   - `PenInventoryStore.load()` replays the server rows (#52) into the pen
///     list, and skips rows that are not pen entries.
///
/// `.serialized` because every case owns the global `MockURLProtocol.handler`.
@Suite("Medication inventory — CU-23 wire (#52 + null first-use)", .serialized)
struct MedicationInventoryCU23WireTests {
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

    /// Captures the request body of the last recorded request.
    private final class BodyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?
        func record(_ data: Data?) {
            lock.lock()
            defer { lock.unlock() }
            value = data
        }

        var snapshot: Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// `URLProtocol` moves `httpBody` onto `httpBodyStream`; re-materialize either.
    private static func body(of request: URLRequest) -> Data? {
        request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var acc = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 { break }
                acc.append(buf, count: read)
            }
            return acc
        }
    }

    private let inventoryRowJSON = #"""
    {"data":{
      "id":"inv-1","userId":"u-1","medicationId":"med-1","state":"ACTIVE",
      "unitsTotal":4,"unitsRemaining":4,"containerType":"PEN",
      "manufacturer":"Novo Nordisk","doseStrength":"1,0 mg","firstUseAt":null,
      "printedExpiry":null,"expiresAt":null,"purchasedAt":"2026-05-01T00:00:00Z",
      "notes":null,"createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z"}}
    """#

    /// PATCH once and hand back the JSON object that was actually transmitted.
    private func sentPatchBody(_ patch: MedicationInventoryPatch) async throws -> [String: Any] {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationTherapyLogRepository(api: api, outbox: outbox)
        let recorder = BodyRecorder()
        let row = inventoryRowJSON
        MockURLProtocol.handler = { req in
            recorder.record(Self.body(of: req))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(row.utf8)
            )
        }
        _ = try await repo.updateInventoryItem(medicationID: "med-1", itemID: "inv-1", patch: patch)
        let data = try #require(recorder.snapshot, "the PATCH must carry a body")
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - A7 — markAsFirstUseAt: null clears the opening date

    @Test("A7: .clear transmits an explicit JSON null for markAsFirstUseAt")
    func clearFirstUseSendsExplicitNull() async throws {
        let json = try await sentPatchBody(MedicationInventoryPatch(markAsFirstUseAt: .clear))
        #expect(json.index(forKey: "markAsFirstUseAt") != nil, "the key MUST be present")
        #expect(json["markAsFirstUseAt"] is NSNull, "an explicit null is what deletes the date")
    }

    @Test("A7: .unchanged omits the key entirely (server leaves the date alone)")
    func unchangedFirstUseOmitsKey() async throws {
        let json = try await sentPatchBody(MedicationInventoryPatch(markAsUsedUp: true))
        #expect(json.index(forKey: "markAsFirstUseAt") == nil, "omission must not read as a clear")
        #expect(json["markAsUsedUp"] as? Bool == true)
    }

    @Test("A7: .set transmits the date value")
    func setFirstUseSendsValue() async throws {
        let json = try await sentPatchBody(
            MedicationInventoryPatch(markAsFirstUseAt: .set(Date(timeIntervalSince1970: 1_780_000_000)))
        )
        let value = json["markAsFirstUseAt"]
        #expect(value != nil)
        #expect(!(value is NSNull), "a set date must never go out as null")
    }

    @Test("M-1: printedExpiry uses the same tri-state (clear vs. omit)")
    func printedExpiryTriState() async throws {
        let cleared = try await sentPatchBody(MedicationInventoryPatch(printedExpiry: .clear))
        #expect(cleared.index(forKey: "printedExpiry") != nil)
        #expect(cleared["printedExpiry"] is NSNull)

        let untouched = try await sentPatchBody(MedicationInventoryPatch(unitsRemaining: 3))
        #expect(untouched.index(forKey: "printedExpiry") == nil)
        #expect(untouched["unitsRemaining"] as? Double == 3)
    }

    @Test("A7: all three states survive the outbox round-trip verbatim")
    func patchRoundTripsThroughTheOutboxPayload() throws {
        let cases: [MedicationInventoryPatch] = [
            MedicationInventoryPatch(markAsFirstUseAt: .clear),
            MedicationInventoryPatch(markAsFirstUseAt: .set(Date(timeIntervalSince1970: 1_780_000_000))),
            MedicationInventoryPatch(markAsUsedUp: true),
            MedicationInventoryPatch(printedExpiry: .clear, unitsRemaining: 2)
        ]
        for patch in cases {
            let data = try JSONEncoder.hlDefault.encode(patch)
            let decoded = try JSONDecoder.hlDefault.decode(MedicationInventoryPatch.self, from: data)
            #expect(decoded == patch, "a replay must re-issue the identical intent")
        }
    }

    // MARK: - #52 — the server rows are replayed into the pen list

    private var serverInventoryListJSON: String {
        #"""
        {"data":{"items":[
          {"id":"srv-pen","userId":"u-1","medicationId":"med-1","state":"IN_USE",
           "unitsTotal":4,"unitsRemaining":2,"containerType":"PEN",
           "manufacturer":"Novo Nordisk","doseStrength":"1,0 mg / Dosis",
           "firstUseAt":"2026-06-01T08:00:00Z","purchasedAt":"2026-05-20T00:00:00Z",
           "createdAt":"2026-05-20T00:00:00Z","updatedAt":"2026-06-01T08:00:00Z","notes":"Web-Eintrag"},
          {"id":"srv-tablets","userId":"u-1","medicationId":"med-1","state":"ACTIVE",
           "unitsTotal":30,"unitsRemaining":30,"containerType":"BLISTER",
           "createdAt":"2026-05-20T00:00:00Z","updatedAt":"2026-05-20T00:00:00Z"}
        ],"meta":{"total":2}}}
        """#
    }

    @MainActor
    private func makePenStore() throws -> PenInventoryStore {
        let container = try GLP1LocalStore.makeInMemory()
        let outbox = try OutboxQueue(inMemory: true)
        let local = GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
        let server = MedicationTherapyLogRepository(api: makeAPI(), outbox: outbox)
        return PenInventoryStore(medicationID: "med-1", repo: local, serverRepo: server)
    }

    @Test("#52: a pen registered on the web renders in the iOS pen list after load")
    @MainActor
    func serverPenIsBackfilled() async throws {
        let list = serverInventoryListJSON
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(list.utf8)
            )
        }
        let store = try makePenStore()
        await store.load()

        #expect(store.pens.count == 1, "only the pen row qualifies, the blister pack does not")
        let pen = try #require(store.pens.first)
        #expect(pen.manufacturer == "Novo Nordisk")
        #expect(pen.doseStrength == "1,0 mg / Dosis")
        #expect(pen.serverID == "srv-pen")
        #expect(pen.notes == "Web-Eintrag")
        #expect(pen.firstUsedAt != nil, "the server's first-use date carries over")
        #expect(store.activePen?.serverID == "srv-pen")
        #expect(store.error == nil)
    }

    @Test("#52: repeated loads converge instead of duplicating the row")
    @MainActor
    func backfillIsIdempotent() async throws {
        let list = serverInventoryListJSON
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(list.utf8)
            )
        }
        let store = try makePenStore()
        await store.load()
        await store.load()
        await store.load()
        #expect(store.pens.count == 1, "the upsert is keyed on the server id")
    }

    @Test("#52: a used-up server row lands in the finished history, not in stock")
    @MainActor
    func usedUpServerRowIsFinished() async throws {
        let list = #"""
        {"data":{"items":[
          {"id":"srv-done","userId":"u-1","medicationId":"med-1","state":"USED_UP",
           "unitsTotal":4,"unitsRemaining":0,"containerType":"PEN",
           "manufacturer":"Lilly","doseStrength":"2,5 mg",
           "firstUseAt":"2026-04-01T08:00:00Z","purchasedAt":"2026-03-20T00:00:00Z",
           "createdAt":"2026-03-20T00:00:00Z","updatedAt":"2026-05-01T08:00:00Z"}
        ],"meta":{"total":1}}}
        """#
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(list.utf8)
            )
        }
        let store = try makePenStore()
        await store.load()
        #expect(store.finishedPens.count == 1)
        #expect(store.unopenedCount == 0)
        #expect(store.activePen == nil)
    }

    @Test("#52: an unreachable server leaves the local pen list standing")
    @MainActor
    func offlineKeepsLocalPens() async throws {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let store = try makePenStore()
        await store.add(
            manufacturer: "Lokal",
            doseStrength: "0,5 mg",
            dispensedAt: Date(timeIntervalSince1970: 1_770_000_000),
            firstUsedAt: nil,
            notes: nil
        )
        await store.load()
        #expect(store.pens.count == 1)
        #expect(store.pens.first?.manufacturer == "Lokal")
        #expect(store.error == nil, "an offline server must not raise a banner on the pen list")
    }
}
