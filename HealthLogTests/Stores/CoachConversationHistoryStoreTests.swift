// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **#30 (v1.18.0) — coach conversation-history *forget* path.**
///
/// Covers `CoachConversationHistoryStore.deleteConversation(id:)` over the *real*
/// `APIClient` + a stubbed `URLSession` (`MockURLProtocol`) — never a mock server
/// (PROJECT_GUIDE.md). Two contracts the swipe-to-delete surface depends on:
///   - happy path: the row is optimistically removed and stays removed once the
///     server confirms (2xx), with no `deleteError`;
///   - failure path (incl. a 404 from a not-yet-deployed route on live ≤ v1.17.1):
///     the row is rolled back into its original position and `deleteError` carries
///     a calm hint — never a crash, list always coherent.
///
/// Serialized because `MockURLProtocol.handler` is shared process-wide state.
@MainActor
@Suite("CoachConversationHistoryStore — forget (delete) path", .serialized)
struct CoachConversationHistoryStoreTests {
    private func makeStore() -> CoachConversationHistoryStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return CoachConversationHistoryStore(repo: CoachConversationHistoryRepository(api: api))
    }

    /// Seed the store's rail with a known three-row list via the list endpoint.
    private func seed(_ store: CoachConversationHistoryStore) async {
        MockURLProtocol.handler = { req in
            let payload = """
            {"data":{"conversations":[\
            {"id":"c1","title":"Sleep","createdAt":"2026-06-10T08:00:00.000Z",\
            "updatedAt":"2026-06-12T08:00:00.000Z","messageCount":4},\
            {"id":"c2","title":"BP","createdAt":"2026-06-09T08:00:00.000Z",\
            "updatedAt":"2026-06-11T08:00:00.000Z","messageCount":2},\
            {"id":"c3","title":"Steps","createdAt":"2026-06-08T08:00:00.000Z",\
            "updatedAt":"2026-06-10T08:00:00.000Z","messageCount":1}\
            ],"nextCursor":null},"error":null}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.load()
    }

    @Test("optimistic remove sticks on a 2xx confirm, with no error")
    func deleteSucceedsAndKeepsRowRemoved() async {
        let store = makeStore()
        await seed(store)
        #expect(store.conversations.count == 3)

        MockURLProtocol.handler = { req in
            // 200 + `{}` so EmptyResponse decodes (empty Data() is not valid JSON).
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data("{}".utf8))
        }
        await store.deleteConversation(id: "c2")

        #expect(store.conversations.map(\.id) == ["c1", "c3"])
        #expect(store.deleteError == nil)
    }

    @Test("a server failure rolls the row back into its original position + sets a calm hint")
    func deleteFailureRollsBack() async {
        let store = makeStore()
        await seed(store)

        MockURLProtocol.handler = { req in
            let payload = """
            {"data":null,"error":"Not found"}
            """
            let http = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (http, Data(payload.utf8))
        }
        await store.deleteConversation(id: "c2")

        // Restored to the middle (original index 1), order intact, calm hint set.
        #expect(store.conversations.map(\.id) == ["c1", "c2", "c3"])
        #expect(store.deleteError != nil)

        store.clearDeleteError()
        #expect(store.deleteError == nil)
    }

    @Test("deleting an unknown id is a no-op (list unchanged, no error)")
    func deleteUnknownIdNoOp() async {
        let store = makeStore()
        await seed(store)
        await store.deleteConversation(id: "does-not-exist")
        #expect(store.conversations.count == 3)
        #expect(store.deleteError == nil)
    }

    /// **v0152 W-COACH-CLEANUP (C3.2) — prior conversation history loads for the
    /// external arm.** The operator expects his OLD conversations available when he
    /// opens the coach. History is server-backed (arm-agnostic) and reached via
    /// `GET /api/insights/chat`; the b198 DELETE work must NOT have gated LOAD off.
    /// This pins that `load()` still hydrates the server-retained conversations.
    @Test("history load hydrates the server-retained conversations (LOAD not gated off by DELETE work)")
    func historyLoadHydrates() async {
        let store = makeStore()
        await seed(store)
        #expect(store.didLoad)
        #expect(store.conversations.map(\.id) == ["c1", "c2", "c3"])
        #expect(store.isCoachDisabled == false)
        #expect(store.error == nil)
    }
}
