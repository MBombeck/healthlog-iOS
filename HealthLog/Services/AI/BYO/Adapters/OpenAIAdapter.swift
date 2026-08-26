import Foundation

/// v0.13 W2 — OpenAI Chat Completions adapter
/// (`POST https://api.openai.com/v1/chat/completions`).
///
/// Auth via `Authorization: Bearer <key>` — header only, never the URL. The
/// validation "ping" is a cheap `GET /v1/models` (no token spend). Pure
/// ``Sendable`` value type: builds the request, parses the body; all I/O lives
/// in ``BYOLLMService``.
public struct OpenAIAdapter: LLMProvider {
    public let id: BYOProviderID = .openAI

    /// Fixed host for the branded OpenAI provider. The generic
    /// ``OpenAICompatibleAdapter`` is the one that takes a user base URL.
    static let host = Self.makeHost()

    private static func makeHost() -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://api.openai.com")!
    }

    public init() {}

    public func makeChatRequest(_ input: LLMChatInput, key: String, baseURL: URL?) throws -> URLRequest {
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        return try Self.makeChatRequest(input, key: key, base: base)
    }

    public func makeValidationRequest(key: String, model _: String?, baseURL: URL?) throws -> URLRequest {
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        return try Self.makeValidationRequest(key: key, base: base)
    }

    public func parseChat(_ data: Data, response _: HTTPURLResponse) throws -> String {
        try Self.parseChat(data)
    }

    public func mapError(status: Int, data: Data) -> BYOLLMError {
        OpenAIWire.mapError(status: status, data: data)
    }

    // MARK: - Shared OpenAI-shape builders (also used by OpenAICompatibleAdapter)

    /// Builds a `/v1/chat/completions` POST against `base`. `key` is empty for
    /// keyless local gateways (Ollama) — the `Authorization` header is then
    /// omitted rather than sent blank.
    static func makeChatRequest(_ input: LLMChatInput, key: String, base: URL) throws -> URLRequest {
        let url = base.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try OpenAIWire.encodeBody(input)
        return request
    }

    static func makeValidationRequest(key: String, base: URL) throws -> URLRequest {
        let url = base.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func parseChat(_ data: Data) throws -> String {
        try OpenAIWire.parseChat(data)
    }
}

// MARK: - OpenAIWire

/// Wire encode/decode for the OpenAI chat-completions shape. Factored out so
/// both ``OpenAIAdapter`` and ``OpenAICompatibleAdapter`` share one body
/// encoder + one response parser + one error mapper.
enum OpenAIWire {
    struct ChatBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let maxTokens: Int
        let temperature: Double
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
        }
    }

    static func encodeBody(_ input: LLMChatInput) throws -> Data {
        var messages: [ChatBody.Message] = []
        if let system = input.system, !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: input.userPrompt))
        let body = ChatBody(
            model: input.model,
            messages: messages,
            maxTokens: input.maxTokens,
            temperature: input.temperature
        )
        return try JSONEncoder().encode(body)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
    }

    static func parseChat(_ data: Data) throws -> String {
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw BYOLLMError.decode("openai: malformed chat body")
        }
        guard let first = decoded.choices.first else {
            throw BYOLLMError.decode("openai: no choices")
        }
        if first.finishReason == "content_filter" {
            throw BYOLLMError.safetyRefused
        }
        let text = (first.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BYOLLMError.decode("openai: empty completion")
        }
        return text
    }

    private struct ErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }

        let error: ErrorBody?
    }

    static func mapError(status: Int, data: Data) -> BYOLLMError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        switch status {
        case 401, 403:
            return .invalidKey
        case 402:
            return .quotaExhausted
        case 404:
            return .modelNotFound
        case 429:
            // OpenAI uses 429 for both rate limits and quota; the error `type`
            // disambiguates `insufficient_quota`.
            if envelope?.error?.type == "insufficient_quota" || envelope?.error?.code == "insufficient_quota" {
                return .quotaExhausted
            }
            return .rateLimited
        case 400:
            return .badRequest(envelope?.error?.message ?? "bad request")
        case 500 ... 599:
            return .providerUnavailable
        default:
            return .badRequest(envelope?.error?.message ?? "http \(status)")
        }
    }
}
