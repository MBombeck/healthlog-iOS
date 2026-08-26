import Foundation

// swiftlint:disable force_unwrapping
@testable import HealthLog
import Testing

/// v0.13 W2 — pure-function coverage for the four BYO ``LLMProvider`` adapters:
/// request-shape (URL, method, auth header, JSON body), success parse from a
/// fixture body, and HTTP→``BYOLLMError`` mapping. No network — adapters are
/// pure value types, so we feed canned `Data` directly.
@Suite("BYO adapters")
struct BYOAdapterTests {
    private func sampleInput(model: String) -> LLMChatInput {
        LLMChatInput(userPrompt: "Wie ist mein Blutdruck?", model: model, maxTokens: 256, temperature: 0.5)
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Force-unwrap helper for known-good URL literals — returning (not an
    /// inline `#require`) so swiftformat does not rewrite it into a `#require`
    /// the compiler flags as redundant for a constant string.
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url("https://example.com"),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - OpenAI

    @Test("OpenAI request shape: URL, bearer header, body")
    func openAIRequest() throws {
        let adapter = OpenAIAdapter()
        let request = try adapter.makeChatRequest(sampleInput(model: "gpt-4o-mini"), key: "sk-test123", baseURL: nil)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test123")
        // Key is in the header, never the URL.
        #expect(request.url?.absoluteString.contains("sk-test123") == false)
        let json = try bodyJSON(request)
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == 256)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "Wie ist mein Blutdruck?")
    }

    @Test("OpenAI validation request is GET /v1/models with bearer")
    func openAIValidation() throws {
        let request = try OpenAIAdapter().makeValidationRequest(key: "sk-abc", model: nil, baseURL: nil)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abc")
    }

    @Test("OpenAI parses assistant text from fixture")
    func openAIParse() throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"Dein Blutdruck ist normal."},"finish_reason":"stop"}]}"#
        let text = try OpenAIAdapter().parseChat(Data(body.utf8), response: http(200))
        #expect(text == "Dein Blutdruck ist normal.")
    }

    @Test("OpenAI error mapping")
    func openAIErrors() {
        let a = OpenAIAdapter()
        #expect(a.mapError(status: 401, data: Data()) == .invalidKey)
        #expect(a.mapError(status: 403, data: Data()) == .invalidKey)
        #expect(a.mapError(status: 429, data: Data()) == .rateLimited)
        let quota = Data(#"{"error":{"type":"insufficient_quota"}}"#.utf8)
        #expect(a.mapError(status: 429, data: quota) == .quotaExhausted)
        #expect(a.mapError(status: 404, data: Data()) == .modelNotFound)
        #expect(a.mapError(status: 503, data: Data()) == .providerUnavailable)
    }

    @Test("OpenAI malformed body → decode error")
    func openAIMalformed() {
        #expect(throws: BYOLLMError.self) {
            _ = try OpenAIAdapter().parseChat(Data("not json".utf8), response: http(200))
        }
    }

    // MARK: - Anthropic

    @Test("Anthropic request shape: x-api-key + version header, system slot")
    func anthropicRequest() throws {
        let input = LLMChatInput(system: "Du bist Coach.", userPrompt: "Hallo", model: "claude-3-5-haiku-latest")
        let request = try AnthropicAdapter().makeChatRequest(input, key: "sk-ant-xyz", baseURL: nil)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-xyz")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.url?.absoluteString.contains("sk-ant-xyz") == false)
        let json = try bodyJSON(request)
        #expect(json["model"] as? String == "claude-3-5-haiku-latest")
        #expect(json["system"] as? String == "Du bist Coach.")
        #expect(json["max_tokens"] != nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "Hallo")
    }

    @Test("Anthropic validation request is a 1-token message")
    func anthropicValidation() throws {
        let request = try AnthropicAdapter().makeValidationRequest(key: "sk-ant-1", model: nil, baseURL: nil)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        let json = try bodyJSON(request)
        #expect(json["max_tokens"] as? Int == 1)
    }

    @Test("Anthropic parses concatenated text blocks")
    func anthropicParse() throws {
        let body = #"{"content":[{"type":"text","text":"Teil eins. "},{"type":"text","text":"Teil zwei."}],"stop_reason":"end_turn"}"#
        let text = try AnthropicAdapter().parseChat(Data(body.utf8), response: http(200))
        #expect(text == "Teil eins. Teil zwei.")
    }

    @Test("Anthropic error mapping incl. 529 overloaded")
    func anthropicErrors() {
        let a = AnthropicAdapter()
        #expect(a.mapError(status: 401, data: Data()) == .invalidKey)
        #expect(a.mapError(status: 429, data: Data()) == .rateLimited)
        #expect(a.mapError(status: 529, data: Data()) == .providerUnavailable)
        #expect(a.mapError(status: 404, data: Data()) == .modelNotFound)
    }

    // MARK: - Gemini

    @Test("Gemini request: model in path, x-goog-api-key header, key NOT in URL")
    func geminiRequest() throws {
        let request = try GeminiAdapter().makeChatRequest(sampleInput(model: "gemini-1.5-flash"), key: "AIzaSecret", baseURL: nil)
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent")
        // The key MUST be in the header, NOT the query (research §4.3).
        #expect(url.contains("AIzaSecret") == false)
        #expect(url.contains("key=") == false)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSecret")
        let json = try bodyJSON(request)
        #expect(json["contents"] != nil)
    }

    @Test("Gemini validation request is GET /v1beta/models with header key")
    func geminiValidation() throws {
        let request = try GeminiAdapter().makeValidationRequest(key: "AIzaX", model: nil, baseURL: nil)
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(url.contains("AIzaX") == false)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaX")
    }

    @Test("Gemini parses candidate parts")
    func geminiParse() throws {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"Antwort von Gemini."}]},"finishReason":"STOP"}]}"#
        let text = try GeminiAdapter().parseChat(Data(body.utf8), response: http(200))
        #expect(text == "Antwort von Gemini.")
    }

    @Test("Gemini error mapping incl. 400 API_KEY_INVALID → invalidKey")
    func geminiErrors() {
        let a = GeminiAdapter()
        #expect(a.mapError(status: 403, data: Data()) == .invalidKey)
        #expect(a.mapError(status: 429, data: Data()) == .rateLimited)
        let keyInvalid = Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#.utf8)
        #expect(a.mapError(status: 400, data: keyInvalid) == .invalidKey)
    }

    @Test("Gemini safety block → safetyRefused")
    func geminiSafety() {
        let body = Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8)
        #expect(throws: BYOLLMError.safetyRefused) {
            _ = try GeminiAdapter().parseChat(body, response: http(200))
        }
    }

    // MARK: - OpenAI-compatible (https-only gate)

    @Test("OpenAI-compatible builds against user base URL")
    func compatibleRequest() throws {
        let base = url("https://gateway.example.com")
        let request = try OpenAICompatibleAdapter().makeChatRequest(sampleInput(model: "local-model"), key: "k", baseURL: base)
        #expect(request.url?.absoluteString == "https://gateway.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test("OpenAI-compatible keyless gateway omits Authorization")
    func compatibleKeyless() throws {
        let base = url("https://ollama.example.com")
        let request = try OpenAICompatibleAdapter().makeChatRequest(sampleInput(model: "llama"), key: "", baseURL: base)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("OpenAI-compatible rejects http:// base URL (https-only, D9)")
    func compatibleRejectsHTTP() throws {
        let base = url("http://192.168.1.10:11434")
        #expect(throws: BYOLLMError.invalidConfiguration("base URL must be https")) {
            _ = try OpenAICompatibleAdapter().makeChatRequest(self.sampleInput(model: "x"), key: "k", baseURL: base)
        }
    }

    @Test("OpenAI-compatible rejects missing base URL")
    func compatibleRejectsMissing() {
        #expect(throws: BYOLLMError.invalidConfiguration("missing base URL")) {
            _ = try OpenAICompatibleAdapter().makeChatRequest(self.sampleInput(model: "x"), key: "k", baseURL: nil)
        }
    }
}
