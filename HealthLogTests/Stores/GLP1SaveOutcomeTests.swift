import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The GLP-1 journal stores answer every save, so their sheets can stay open
/// on a failure instead of closing over a lost entry. A row the server refused
/// is taken back off the device, so a second attempt does not log it twice.
/// Real `APIClient` over a stubbed `URLSession`.
@MainActor
@Suite("GLP-1 save outcomes", .serialized, .mockURLSession)
struct GLP1SaveOutcomeTests {
    private let medID = "med-1"

    private func makeLocalRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    private func makeServerRepo() throws -> MedicationTherapyLogRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try MedicationTherapyLogRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    private static func respond(_ status: Int, _ body: String) {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
    }

    private static let validationError = #"{"data":null,"error":{"code":"VALIDATION","message":"Invalid entry"}}"#

    private static let sideEffectRow = #"""
    {"data":{"id":"se-1","userId":"u-1","medicationId":"med-1","category":"GI","entry":"NAUSEA",
    "severity":3,"occurredAt":"2026-05-01T08:00:00Z","notes":null,
    "createdAt":"2026-05-01T08:00:01Z","updatedAt":"2026-05-01T08:00:01Z"}}
    """#

    /// What one save left behind: the store, its answer and the rows on the device.
    private struct Outcome<Store> {
        let store: Store
        let failure: HLError?
        let stored: Int
    }

    private static let notFound = #"{"data":null,"error":"Not found"}"#
    private static let brokenCreated = #"{"data":{"unexpected":true}}"#
    private static let unavailable = #"{"data":null,"error":"Service unavailable"}"#

    private func logSideEffect(status: Int, body: String) async throws -> Outcome<SideEffectsLogbookStore> {
        let local = try makeLocalRepo()
        let store = try SideEffectsLogbookStore(medicationID: medID, repo: local, serverRepo: makeServerRepo())
        Self.respond(status, body)
        let failure = await store.log(loggedAt: .now, kind: .nausea, severity: 2, note: "after lunch")
        let stored = try await local.sideEffects(medicationID: medID, sinceDays: 90).count
        return Outcome(store: store, failure: failure, stored: stored)
    }

    private func addPen(status: Int, body: String) async throws -> Outcome<PenInventoryStore> {
        let local = try makeLocalRepo()
        let store = try PenInventoryStore(medicationID: medID, repo: local, serverRepo: makeServerRepo())
        Self.respond(status, body)
        let failure = await store.add(
            manufacturer: "Novo Nordisk", doseStrength: "1 mg", dispensedAt: .now, firstUsedAt: nil, notes: nil
        )
        let stored = try await local.pens(medicationID: medID).count
        return Outcome(store: store, failure: failure, stored: stored)
    }

    // MARK: - Side effects

    @Test("A side effect the server rejects as invalid is taken back and reported")
    func sideEffectRejected() async throws {
        let outcome = try await logSideEffect(status: 422, body: Self.validationError)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure != nil)
        #expect(store.entries.isEmpty)
        #expect(stored == 0, "a rejected entry must not stay on the device")
        #expect(store.error == nil, "the sheet shows the failure, not the banner")
    }

    @Test("A side effect the server accepts reports success and shows the row")
    func sideEffectSaved() async throws {
        let outcome = try await logSideEffect(status: 201, body: Self.sideEffectRow)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.entries.count == 1)
        #expect(stored == 1)
        #expect(store.error == nil)
    }

    @Test("A side effect whose 2xx answer will not decode stays, with a banner")
    func sideEffectUndecodableAnswerStays() async throws {
        let outcome = try await logSideEffect(status: 201, body: Self.brokenCreated)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.entries.count == 1)
        #expect(stored == 1, "the server has the entry, so the device keeps it")
        #expect(store.error != nil)
    }

    @Test("A side effect on a server without the route stays on the device")
    func sideEffectUnknownRouteStays() async throws {
        let outcome = try await logSideEffect(status: 404, body: Self.notFound)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.entries.count == 1)
        #expect(stored == 1)
        #expect(store.error != nil)
    }

    @Test("A side effect while the server is unavailable is queued and stays")
    func sideEffectQueuedStays() async throws {
        let outcome = try await logSideEffect(status: 503, body: Self.unavailable)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.entries.count == 1)
        #expect(stored == 1)
        #expect(store.error == nil, "a queued write is not an error")
    }

    // MARK: - Pens

    @Test("A pen the server rejects as invalid is taken back and reported")
    func penRejected() async throws {
        let outcome = try await addPen(status: 422, body: Self.validationError)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure != nil)
        #expect(store.pens.isEmpty)
        #expect(stored == 0)
        #expect(store.error == nil)
    }

    @Test("A pen whose 2xx answer will not decode stays, with a banner")
    func penUndecodableAnswerStays() async throws {
        let outcome = try await addPen(status: 201, body: Self.brokenCreated)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.pens.count == 1)
        #expect(stored == 1)
        #expect(store.error != nil)
    }

    @Test("A pen on a server without the route stays on the device")
    func penUnknownRouteStays() async throws {
        let outcome = try await addPen(status: 404, body: Self.notFound)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.pens.count == 1)
        #expect(stored == 1)
        #expect(store.error != nil)
    }

    @Test("A pen while the server is unavailable is queued and stays")
    func penQueuedStays() async throws {
        let outcome = try await addPen(status: 503, body: Self.unavailable)
        let (store, failure, stored) = (outcome.store, outcome.failure, outcome.stored)
        #expect(failure == nil)
        #expect(store.pens.count == 1)
        #expect(stored == 1)
        #expect(store.error == nil)
    }

    @Test("Saving a titration step answers success, deleting reports it too")
    func titrationAnswers() async throws {
        let store = try TitrationLadderStore(medicationID: medID, catalogDrug: nil, repo: makeLocalRepo())

        let failure = await store.add(effectiveFrom: .now, doseMg: 0.5, note: nil)
        #expect(failure == nil)
        let id = try #require(store.localSteps.first?.id)

        let deleted = await store.delete(id: id)
        #expect(deleted)
        #expect(store.localSteps.isEmpty)
        #expect(store.error == nil)
    }

    /// #169 — a site belongs to a dose; without one (and without a server)
    /// there is nothing to write and nothing fails.
    @Test("Setting a site without a recorded dose answers no write")
    func injectionSiteAnswers() async throws {
        let store = try InjectionSiteStore(medicationID: medID, repo: makeLocalRepo())
        await store.load(serverIntakes: [])
        let written = await store.setSiteOnLastInjection(.thighLeft)
        #expect(!written)
        #expect(!store.canSetSite)
        #expect(store.error == nil)
        #expect(store.notice == nil)
    }
}
