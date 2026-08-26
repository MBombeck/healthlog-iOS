import Foundation
@testable import HealthLog
import Testing

/// State-machine tests for `AIProviderStore`. Locks the lifecycle that the
/// M2-A3 audit demanded: GET-on-load populates drafts, draft changes never
/// hit the network until save, save composes a minimal PATCH, errors surface
/// without clobbering draft state.
@MainActor
@Suite("AIProviderStore")
struct AIProviderStoreTests {
    // MARK: - Stub APIClient

    /// Handler-based stub: each `send(_:)` invocation calls the registered
    /// handler with the raw request — tests assert on captured PATCH bodies
    /// and return decoded payloads of any concrete `Sendable` shape.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        var sendHandler: (@Sendable (any Sendable) async throws -> any Sendable)?

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let handler = sendHandler else { throw HLError.unknown("no handler") }
            let result = try await handler(request)
            guard let typed = result as? T else {
                throw HLError.decoding("type mismatch — handler returned \(type(of: result)), expected \(T.self)")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    /// Alias to `AIProviderRepository.UpdateResponse` — the nested
    /// `{ updated: Bool? }` shape the repo decodes from PATCH responses
    /// before re-fetching GET. Using the real type matters: the runtime
    /// cast `as? APIRequest<UpdateResponse>` only succeeds when the
    /// generic argument is identical to the one the repo uses.
    private typealias PatchAck = AIProviderRepository.UpdateResponse

    /// Convenience handler — answers GET with the supplied config, captures
    /// PATCH bodies into the given collection, and returns a `PatchAck`.
    @MainActor
    private final class Capture {
        var patches: [Data] = []
        var getResponse: AIProviderConfig
        var subsequentGets: [AIProviderConfig] = []
        var errorOnNext: HLError?

        init(initial: AIProviderConfig) {
            getResponse = initial
        }

        func handler() -> @Sendable (any Sendable) async throws -> any Sendable {
            // Strong capture intentional — `Capture` is held by the test
            // closure scope; the handler must always answer requests.
            { req in
                if let err = await self.takeError() { throw err }
                if let r = req as? APIRequest<AIProviderConfig> {
                    _ = r
                    return await self.nextGet()
                }
                if let r = req as? APIRequest<PatchAck> {
                    if let body = r.body {
                        await self.capturePatch(body)
                    }
                    return PatchAck(updated: true)
                }
                throw HLError.unknown("unexpected request shape: \(type(of: req))")
            }
        }

        func nextGet() -> AIProviderConfig {
            if let next = subsequentGets.first {
                subsequentGets.removeFirst()
                getResponse = next
                return next
            }
            return getResponse
        }

        func capturePatch(_ body: Data) {
            patches.append(body)
        }

        func takeError() -> HLError? {
            defer { errorOnNext = nil }
            return errorOnNext
        }
    }

    private func makeStore(initial: AIProviderConfig = .init()) -> (AIProviderStore, Capture) {
        let stub = StubAPIClient()
        let capture = Capture(initial: initial)
        stub.sendHandler = capture.handler()
        let repo = AIProviderRepository(api: stub)
        return (AIProviderStore(repo: repo), capture)
    }

    // MARK: - Load path

    @Test("load() populates config + drafts from server")
    func loadPopulatesDrafts() async {
        let config = AIProviderConfig(
            provider: "ANTHROPIC",
            model: "provider-model-v1",
            baseUrl: nil,
            hasAnthropicKey: true,
            anthropicKeyPreview: "...AB12"
        )
        let (store, _) = makeStore(initial: config)

        await store.load()

        #expect(store.config?.provider == "ANTHROPIC")
        #expect(store.draftProvider == .anthropic)
        #expect(store.draftModel == "provider-model-v1")
        #expect(store.draftBaseUrl == "")
        #expect(store.draftAPIKey == "")
        #expect(store.error == nil)
        #expect(store.isLoading == false)
        #expect(store.serverProvider == .anthropic)
        #expect(store.isServerFullyConfigured == true)
        #expect(store.serverKeyPreview == "...AB12")
    }

    @Test("load() with no provider configured resolves to .unconfigured")
    func loadUnconfigured() async {
        let (store, _) = makeStore(initial: AIProviderConfig())

        await store.load()

        #expect(store.draftProvider == .unconfigured)
        #expect(store.serverProvider == .unconfigured)
        #expect(store.isServerFullyConfigured == false)
        #expect(store.serverKeyPreview == nil)
    }

    @Test("load() surfaces server errors without clobbering existing state")
    func loadErrorPath() async {
        let (store, capture) = makeStore()
        capture.errorOnNext = .server(status: 500, code: nil, message: "boom")

        await store.load()

        #expect(store.config == nil)
        #expect(store.error != nil)
        if case let .server(status, _, _) = store.error {
            #expect(status == 500)
        } else {
            Issue.record("Expected .server error, got \(String(describing: store.error))")
        }
    }

    // MARK: - hasUnsavedChanges

    @Test("hasUnsavedChanges flips when user changes provider")
    func dirtyOnProviderChange() async {
        let config = AIProviderConfig(provider: "ANTHROPIC", hasAnthropicKey: true)
        let (store, _) = makeStore(initial: config)
        await store.load()

        #expect(store.hasUnsavedChanges == false)
        store.draftProvider = .openai
        #expect(store.hasUnsavedChanges == true)
    }

    @Test("hasUnsavedChanges flips when user types an API key")
    func dirtyOnAPIKeyEntry() async {
        let config = AIProviderConfig(provider: "ANTHROPIC", hasAnthropicKey: true)
        let (store, _) = makeStore(initial: config)
        await store.load()

        store.draftAPIKey = "sk-ant-..."
        #expect(store.hasUnsavedChanges == true)
    }

    @Test("hasUnsavedChanges stays false when only whitespace is typed in model")
    func cleanWhenWhitespaceModel() async {
        let config = AIProviderConfig(provider: "OPENAI", model: "gpt-4o", hasOpenaiKey: true)
        let (store, _) = makeStore(initial: config)
        await store.load()

        store.draftModel = "gpt-4o   "
        #expect(store.hasUnsavedChanges == false)
    }

    // MARK: - Save path

    @Test("save() sends a PATCH with only the changed provider field")
    func savePatchesOnlyProvider() async throws {
        let config = AIProviderConfig(provider: "ANTHROPIC", hasAnthropicKey: true)
        let (store, capture) = makeStore(initial: config)
        await store.load()

        store.draftProvider = .openai
        capture.subsequentGets = [AIProviderConfig(provider: "OPENAI", hasOpenaiKey: false)]
        await store.save()

        let body = try #require(capture.patches.first)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["provider"] as? String == "OPENAI")
        #expect(decoded["openaiKey"] == nil)
        #expect(decoded["anthropicKey"] == nil)
        #expect(decoded["model"] == nil)
        #expect(decoded["baseUrl"] == nil)
    }

    @Test("save() includes the API key when user typed one")
    func savePatchesIncludesKey() async throws {
        let (store, capture) = makeStore()
        await store.load()

        store.draftProvider = .openai
        store.draftAPIKey = "sk-real-key"
        capture.subsequentGets = [AIProviderConfig(provider: "OPENAI", hasOpenaiKey: true)]
        await store.save()

        let body = try #require(capture.patches.first)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["provider"] as? String == "OPENAI")
        #expect(decoded["openaiKey"] as? String == "sk-real-key")
        #expect(decoded["anthropicKey"] == nil)
        // Picker switched to OpenAI — the LOCAL-only baseUrl must NOT be sent
        // (server would otherwise reject if value were a private host).
        #expect(decoded["baseUrl"] == nil)
    }

    @Test("save() clears the draftAPIKey after success so it isn't kept in memory")
    func saveClearsDraftAPIKey() async {
        let (store, capture) = makeStore()
        await store.load()

        store.draftProvider = .openai
        store.draftAPIKey = "sk-secret"
        capture.subsequentGets = [AIProviderConfig(
            provider: "OPENAI",
            hasOpenaiKey: true,
            openaiKeyPreview: "...cret"
        )]
        await store.save()

        #expect(store.draftAPIKey == "")
        #expect(store.didJustSave == true)
        #expect(store.config?.openaiKeyPreview == "...cret")
    }

    @Test("save() error preserves draftAPIKey so the user can retry")
    func saveErrorPreservesKey() async {
        let (store, capture) = makeStore()
        await store.load()

        store.draftProvider = .anthropic
        store.draftAPIKey = "sk-typed"
        capture.errorOnNext = .server(status: 422, code: "Invalid provider", message: "boom")
        await store.save()

        #expect(store.draftAPIKey == "sk-typed")
        #expect(store.didJustSave == false)
        #expect(store.error != nil)
    }

    @Test("save() routes the typed key to the right server field per provider")
    func saveRoutesKeyByProvider() async throws {
        let cases: [(AIProvider, String)] = [
            (.anthropic, "anthropicKey"),
            (.openai, "openaiKey"),
            (.local, "localKey")
        ]
        for (provider, expectedField) in cases {
            let (store, capture) = makeStore()
            await store.load()
            store.draftProvider = provider
            store.draftAPIKey = "k-\(provider.rawValue)"
            if provider == .local {
                store.draftBaseUrl = "https://ollama.example.com"
            }
            capture.subsequentGets = [AIProviderConfig(provider: provider.wireValue)]
            await store.save()
            let body = try #require(capture.patches.first)
            let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(
                decoded[expectedField] as? String == "k-\(provider.rawValue)",
                "Provider \(provider) should route key to \(expectedField)"
            )
        }
    }

    @Test("clearAPIKey sends an explicit null for the active provider's key field")
    func clearAPIKeySendsNull() async throws {
        let config = AIProviderConfig(provider: "OPENAI", hasOpenaiKey: true, openaiKeyPreview: "...AB12")
        let (store, capture) = makeStore(initial: config)
        await store.load()

        capture.subsequentGets = [AIProviderConfig(provider: "OPENAI", hasOpenaiKey: false)]
        await store.clearAPIKey()

        let body = try #require(capture.patches.first)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["openaiKey"] is NSNull)
        // No provider change should be sent — we just clear the key.
        #expect(decoded["provider"] == nil)
    }

    @Test("unknown available provider is presented as server-configured")
    func loadProviderOpaqueAvailability() async {
        let config = AIProviderConfig(
            provider: "FUTURE_OAUTH",
            aiAvailable: true,
            managedBy: "user"
        )
        let (store, _) = makeStore(initial: config)

        await store.load()

        #expect(store.serverProvider == .unconfigured)
        #expect(store.usesProviderOpaqueAIConsent)
        #expect(store.isServerAIAvailable)
        #expect(store.isServerFullyConfigured)
        #expect(store.hasUnsavedChanges == false)
    }
}
