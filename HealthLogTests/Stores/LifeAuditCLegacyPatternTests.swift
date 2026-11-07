// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **POLISH-C (C7)** — the one-word alcohol answer asked before AUDIT-C
/// (`ALCOHOL_PATTERN`) is still part of the record. Like the web's
/// `audit-c-panel.tsx` (v1.47.0), the alcohol section shows it with a way to
/// remove it, read from `GET /api/anamnesis/facts`, and nothing when there is
/// none, when its value is one this build cannot name, or when the server has
/// no AUDIT-C at all.
@MainActor
@Suite("AUDIT-C: the earlier alcohol answer", .serialized, .mockURLSession)
struct LifeAuditCLegacyPatternTests {
    private func makeStore(_ server: LifeServerStub) -> LifeCircumstancesStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        MockURLProtocol.install { request in server.handle(request) }
        return LifeCircumstancesStore(repo: LifeCircumstancesRepository(api: api))
    }

    @Test("a stored pattern is shown with its own label, and can be removed")
    func storedPatternIsShownAndRemoved() async throws {
        let server = LifeServerStub()
        server.seed(kind: "ALCOHOL_PATTERN", valueJSON: #""WEEKLY""#, id: "fact-alcohol")
        let store = makeStore(server)
        await store.load()

        let legacy = try #require(store.legacyAlcohol)
        #expect(legacy.id == "fact-alcohol")
        #expect(legacy.value == .weekly)
        #expect(AuditCLegacyRow.valueLabel(legacy) == String(localized: "anamnesis.value.ALCOHOL_PATTERN.WEEKLY"))

        let model = AuditCModel()
        model.askLegacyRemoval()
        #expect(model.isConfirmingLegacyRemoval)
        await model.removeLegacy(store: store)
        #expect(server.requests.contains { $0.method == "DELETE" && $0.path == "/api/anamnesis/facts/fact-alcohol" })
        #expect(store.legacyAlcohol == nil)
        #expect(model.isConfirmingLegacyRemoval == false)
        #expect(model.legacyRemoveError == nil)
    }

    @Test("no stored pattern, no row")
    func nothingStored() async {
        let server = LifeServerStub()
        let store = makeStore(server)
        await store.load()
        #expect(store.payload != nil)
        #expect(store.legacyAlcohol == nil)
    }

    @Test("a value this build cannot name is not shown")
    func unknownValueIsNotShown() async {
        let server = LifeServerStub()
        server.seed(kind: "ALCOHOL_PATTERN", valueJSON: #""BINGE_WEEKENDS""#, id: "fact-new")
        let store = makeStore(server)
        await store.load()
        #expect(store.legacyAlcohol == nil)
    }

    @Test("a server without AUDIT-C is not asked for the facts")
    func olderServerIsNotAsked() async {
        let server = LifeServerStub()
        server.offersAuditC = false
        server.seed(kind: "ALCOHOL_PATTERN", valueJSON: #""WEEKLY""#, id: "fact-alcohol")
        let store = makeStore(server)
        await store.load()
        #expect(store.payload?.auditC == nil)
        #expect(store.legacyAlcohol == nil)
        #expect(!server.requests.contains { $0.path == "/api/anamnesis/facts" })
    }

    @Test("a failing facts read keeps the page and shows no row")
    func failingFactsReadKeepsThePage() async {
        let server = LifeServerStub()
        server.seed(kind: "ALCOHOL_PATTERN", valueJSON: #""WEEKLY""#, id: "fact-alcohol")
        server.override("GET /api/anamnesis/facts", status: 500, body: #"{"data":null,"error":"boom"}"#)
        let store = makeStore(server)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.legacyAlcohol == nil)
    }

    @Test("a refused removal keeps the question open with its sentence")
    func refusedRemovalKeepsTheQuestion() async throws {
        let server = LifeServerStub()
        server.seed(kind: "ALCOHOL_PATTERN", valueJSON: #""OCCASIONAL""#, id: "fact-alcohol")
        let store = makeStore(server)
        await store.load()
        _ = try #require(store.legacyAlcohol)
        server.override("DELETE /api/anamnesis/facts/fact-alcohol", status: 500, body: #"{"data":null,"error":"boom"}"#)

        let model = AuditCModel()
        model.askLegacyRemoval()
        await model.removeLegacy(store: store)
        #expect(model.isConfirmingLegacyRemoval)
        #expect(model.legacyRemoveError == String(localized: "life.auditC.legacy.removeError"))
        #expect(store.legacyAlcohol != nil)
    }
}
