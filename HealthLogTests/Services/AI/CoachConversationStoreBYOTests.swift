import Foundation

// swiftlint:disable force_unwrapping
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// v0.13 W4 — Coach BYO-key arm routing. With `aiMode == .byoKey` (a granted +
/// stored key) the store must route the turn through the BYO arm
/// (`BYOLLMService.generate`) and surface the provider's text on the same
/// `chat` / `isResponding` / `lastError` consumer surface. On a `BYOLLMError`
/// it must show the honest mapped error, not crash.
///
/// The `BYOLLMService` is the real actor driven through a stubbed `URLSession`
/// (the repo's `MockURLProtocol`, never a mock server), per PROJECT_GUIDE.md.
@MainActor
@Suite("CoachConversationStore — BYO arm", .serialized)
struct CoachConversationStoreBYOTests {
    private func makeSession() -> URLSession {
        URLSession(configuration: .mock())
    }

    /// Builds a store wired with a BYO service + a resolver pinned to `.openAI`,
    /// granting consent so the gate lets the request through.
    private func makeStore(keychain: InMemoryKeychain) -> CoachConversationStore {
        let keyStore = BYOKeyStore(keychain: keychain)
        let byoService = BYOLLMService(
            keyStore: keyStore,
            session: makeSession(),
            consentGate: { _ in true }
        )
        let store = CoachConversationStore(service: LocalLLMService())
        store.byoService = byoService
        store.byoProviderResolver = { .openAI }
        return store
    }

    @Test("routes to BYO arm and surfaces the provider text")
    func routesToBYO() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        let store = makeStore(keychain: keychain)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"choices":[{"message":{"content":"Dein Blutdruck ist okay."}}]}"#
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        #expect(store.shouldUseBYO)
        await store.send("Wie ist mein Blutdruck?")

        // user + assistant turn landed, assistant carries the provider text.
        #expect(store.chat.count == 2)
        #expect(store.usingBYO)
        #expect(store.lastError == nil)
        #expect(store.isResponding == false)
        #if canImport(SpeziChat)
            #expect(store.chat.last?.role == .assistant)
            #expect(store.chat.last?.content == "Dein Blutdruck ist okay.")
        #endif
    }

    @Test("BYO invalid-key surfaces honest error, not a crash")
    func byoInvalidKey() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-bad", for: .openAI)
        let store = makeStore(keychain: keychain)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await store.send("Frage")

        // User turn stays for a retry; assistant turn missing; honest error set.
        #expect(store.chat.count == 1)
        #expect(store.isResponding == false)
        guard case .byoFailed(.invalidKey) = store.lastError else {
            Issue.record("expected .byoFailed(.invalidKey), got \(String(describing: store.lastError))")
            return
        }
    }

    @Test("no BYO provider resolved → BYO arm not selected")
    func noProviderNotSelected() {
        let store = CoachConversationStore(service: LocalLLMService())
        store.byoService = BYOLLMService(keyStore: BYOKeyStore(keychain: InMemoryKeychain()))
        store.byoProviderResolver = { nil }
        #expect(store.shouldUseBYO == false)
    }
}
