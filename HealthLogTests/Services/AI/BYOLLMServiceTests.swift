import Foundation

// swiftlint:disable force_unwrapping
@testable import HealthLog
import Testing

/// v0.13 W2 — ``BYOLLMService`` end-to-end coverage through a stubbed
/// `URLSession` (the repo's `MockURLProtocol`, never a mock server). Asserts
/// the actor reads the stored key, builds the right request via the adapter,
/// parses success, maps HTTP errors to ``BYOLLMError``, and validates keys.
///
/// Thread-safe capture box for the `@Sendable` `MockURLProtocol` handler —
/// lets a request-shape assertion read a header the stub saw without a
/// captured-var data race.
private final class CapturedHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: String?
    var authorization: String? {
        lock.lock()
        defer { lock.unlock() }
        return _authorization
    }

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        _authorization = value
    }
}

/// `.serialized` — `MockURLProtocol.handler` is process-global state.
@Suite("BYOLLMService", .serialized)
struct BYOLLMServiceTests {
    private func makeSession() -> URLSession {
        URLSession(configuration: .mock())
    }

    private func makeService(keychain: InMemoryKeychain = InMemoryKeychain()) -> BYOLLMService {
        BYOLLMService(keyStore: BYOKeyStore(keychain: keychain), session: makeSession())
    }

    /// Force-unwrap helper for known-good URL literals — returning (not an
    /// inline `#require`) so swiftformat does not rewrite it into a `#require`
    /// the compiler flags as redundant for a constant string.
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private func ok(_ json: String) -> MockURLProtocol.Handler {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }

    private func fail(_ status: Int, _ json: String = "{}") -> MockURLProtocol.Handler {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }

    @Test("generate reads stored key and returns parsed OpenAI text")
    func generateOpenAI() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        let service = BYOLLMService(keyStore: keyStore, session: makeSession())

        let captured = CapturedHeaders()
        MockURLProtocol.handler = { request in
            captured.set(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"choices":[{"message":{"content":"Hallo!"},"finish_reason":"stop"}]}"#
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let text = try await service.generate(prompt: "Frage", provider: .openAI)
        #expect(text == "Hallo!")
        #expect(captured.authorization == "Bearer sk-stored")
    }

    @Test("generate with no stored key throws invalidConfiguration")
    func generateMissingKey() async {
        let service = makeService()
        await #expect(throws: BYOLLMError.self) {
            _ = try await service.generate(prompt: "x", provider: .openAI)
        }
    }

    /// v0.13 W4 — consent enforcement (Apple 5.1.2(i)). With a consent gate that
    /// denies, `generate` must THROW before any network call — even with a stored
    /// key. The MockURLProtocol handler records whether it was ever invoked; it
    /// must NOT be, proving no un-consented transmission can fire.
    @Test("generate throws and fires NO request when BYO consent is absent")
    func generateThrowsWithoutConsent() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        let service = BYOLLMService(
            keyStore: keyStore,
            session: makeSession(),
            consentGate: { _ in false } // consent denied
        )
        let requestFired = CapturedHeaders()
        MockURLProtocol.handler = { request in
            requestFired.set("FIRED")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await #expect(throws: BYOLLMError.self) {
            _ = try await service.generate(prompt: "leak?", provider: .openAI)
        }
        #expect(requestFired.authorization == nil, "no network call may fire without consent")
    }

    /// Counterpart: a granting gate lets the request through normally.
    @Test("generate proceeds when BYO consent is granted")
    func generateProceedsWithConsent() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        let service = BYOLLMService(
            keyStore: keyStore,
            session: makeSession(),
            consentGate: { _ in true }
        )
        MockURLProtocol.handler = ok(#"{"choices":[{"message":{"content":"Hi"}}]}"#)
        defer { MockURLProtocol.handler = nil }

        let text = try await service.generate(prompt: "ok", provider: .openAI)
        #expect(text == "Hi")
    }

    @Test("generate maps 401 to invalidKey")
    func generate401() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-bad", for: .openAI)
        let service = BYOLLMService(keyStore: keyStore, session: makeSession())
        MockURLProtocol.handler = fail(401)
        defer { MockURLProtocol.handler = nil }

        await #expect(throws: BYOLLMError.invalidKey) {
            _ = try await service.generate(prompt: "x", provider: .openAI)
        }
    }

    @Test("generate maps 429 to rateLimited")
    func generate429() async throws {
        let service = makeService()
        MockURLProtocol.handler = fail(429)
        defer { MockURLProtocol.handler = nil }
        await #expect(throws: BYOLLMError.rateLimited) {
            _ = try await service.generate(prompt: "Q", provider: .gemini, key: "AIza", model: nil, baseURL: nil)
        }
    }

    @Test("generate maps malformed 200 body to decode error")
    func generateMalformed() async {
        let service = makeService()
        MockURLProtocol.handler = ok("not json at all")
        defer { MockURLProtocol.handler = nil }
        await #expect(throws: BYOLLMError.self) {
            _ = try await service.generate(prompt: "Q", provider: .openAI, key: "sk-x", model: nil, baseURL: nil)
        }
    }

    @Test("validate returns success on 200")
    func validateSuccess() async {
        let service = makeService()
        MockURLProtocol.handler = ok(#"{"data":[]}"#)
        defer { MockURLProtocol.handler = nil }
        let result = await service.validate(provider: .openAI, key: "sk-good", model: nil, baseURL: nil)
        if case .success = result {
            // expected
        } else {
            Issue.record("expected success, got \(result)")
        }
    }

    @Test("validate returns invalidKey on 401")
    func validateInvalid() async {
        let service = makeService()
        MockURLProtocol.handler = fail(401)
        defer { MockURLProtocol.handler = nil }
        let result = await service.validate(provider: .anthropic, key: "sk-ant-bad", model: nil, baseURL: nil)
        if case .failure(.invalidKey) = result {
            // expected
        } else {
            Issue.record("expected invalidKey, got \(result)")
        }
    }

    @Test("validate rejects empty key without a request")
    func validateEmptyKey() async {
        let service = makeService()
        let result = await service.validate(provider: .openAI, key: "   ", model: nil, baseURL: nil)
        if case .failure(.invalidConfiguration) = result {
            // expected
        } else {
            Issue.record("expected invalidConfiguration, got \(result)")
        }
    }

    @Test("validate rejects http:// compatible base URL (https-only)")
    func validateRejectsHTTP() async {
        let service = makeService()
        let result = await service.validate(
            provider: .openAICompatible,
            key: "k",
            model: nil,
            baseURL: url("http://192.168.1.5:11434")
        )
        if case .failure(.invalidConfiguration) = result {
            // expected — the https gate fires before any request
        } else {
            Issue.record("expected invalidConfiguration for http baseURL, got \(result)")
        }
    }
}
