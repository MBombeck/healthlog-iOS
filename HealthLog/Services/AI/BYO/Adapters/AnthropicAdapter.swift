import Foundation

/// v0.13 W2 — Anthropic Messages adapter
/// (`POST https://api.anthropic.com/v1/messages`).
///
/// Auth via the `x-api-key: <key>` header plus the required
/// `anthropic-version: 2023-06-01` header. Header only — never the URL.
/// Anthropic requires `max_tokens` and carries the system preamble in a
/// dedicated top-level `system` field (not a message). Validation "ping" is a
/// minimal 1-token completion — there is no key-validating models GET, so the
/// cheapest honest check is a `max_tokens: 1` message.
public struct AnthropicAdapter: LLMProvider {
    public let id: BYOProviderID = .anthropic

    // swiftlint:disable:next force_unwrapping
    static let host = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"

    public init() {}

    public func makeChatRequest(_ input: LLMChatInput, key: String, baseURL: URL?) throws -> URLRequest {
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        return try Self.request(input: input, key: key, base: base)
    }

    public func makeValidationRequest(key: String, model: String?, baseURL: URL?) throws -> URLRequest {
        // No cheap models-GET that validates the key; use a 1-token message.
        let ping = LLMChatInput(
            userPrompt: "ping",
            model: model ?? BYOProviderID.anthropic.defaultModel,
            maxTokens: 1,
            temperature: 0
        )
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        return try Self.request(input: ping, key: key, base: base)
    }

    public func parseChat(_ data: Data, response _: HTTPURLResponse) throws -> String {
        let decoded: MessageResponse
        do {
            decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            throw BYOLLMError.decode("anthropic: malformed message body")
        }
        if decoded.stopReason == "refusal" {
            throw BYOLLMError.safetyRefused
        }
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BYOLLMError.decode("anthropic: empty completion")
        }
        return text
    }

    public func mapError(status: Int, data: Data) -> BYOLLMError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        switch status {
        case 401, 403:
            return .invalidKey
        case 404:
            return .modelNotFound
        case 429:
            return .rateLimited
        case 400:
            return .badRequest(envelope?.error?.message ?? "bad request")
        case 500 ... 599, 529: // 529 = Anthropic "overloaded"
            return .providerUnavailable
        default:
            return .badRequest(envelope?.error?.message ?? "http \(status)")
        }
    }

    // MARK: - Wire

    private static func request(input: LLMChatInput, key: String, base: URL) throws -> URLRequest {
        let url = base.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try encodeBody(input)
        return request
    }

    private struct MessageBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let maxTokens: Int
        let temperature: Double
        let system: String?
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, temperature, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private static func encodeBody(_ input: LLMChatInput) throws -> Data {
        let body = MessageBody(
            model: input.model,
            maxTokens: input.maxTokens,
            temperature: input.temperature,
            system: input.system,
            messages: [.init(role: "user", content: input.userPrompt)]
        )
        return try JSONEncoder().encode(body)
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    struct ErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let type: String?
            let message: String?
        }

        let error: ErrorBody?
    }
}
