import Foundation

/// v0.13 W2 — Google Gemini adapter
/// (`POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`).
///
/// **Key in the header, NOT the query.** Gemini accepts the key either as a
/// `?key=` query param or an `x-goog-api-key` header — we use the **header**
/// exclusively so the key can never land in a logged `URLRequest.url` (research
/// §4.3, defence-in-depth alongside `LogSanitizer`). The model id is part of
/// the path (`models/<model>:generateContent`). The system preamble rides in
/// the dedicated `systemInstruction` field. Validation "ping" is a cheap
/// `GET /v1beta/models` with the same header auth.
public struct GeminiAdapter: LLMProvider {
    public let id: BYOProviderID = .gemini

    // swiftlint:disable:next force_unwrapping
    static let host = URL(string: "https://generativelanguage.googleapis.com")!
    static let headerName = "x-goog-api-key"

    public init() {}

    public func makeChatRequest(_ input: LLMChatInput, key: String, baseURL: URL?) throws -> URLRequest {
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        let url = base.appendingPathComponent("v1beta/models/\(input.model):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: Self.headerName)
        request.httpBody = try Self.encodeBody(input)
        return request
    }

    public func makeValidationRequest(key: String, model _: String?, baseURL: URL?) throws -> URLRequest {
        let base = try OpenAICompatibleAdapter.resolvedHTTPSBase(baseURL, default: Self.host)
        let url = base.appendingPathComponent("v1beta/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: Self.headerName)
        return request
    }

    public func parseChat(_ data: Data, response _: HTTPURLResponse) throws -> String {
        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw BYOLLMError.decode("gemini: malformed generateContent body")
        }
        guard let candidate = decoded.candidates?.first else {
            // A prompt blocked by the safety filter returns no candidates +
            // a promptFeedback.blockReason.
            if decoded.promptFeedback?.blockReason != nil {
                throw BYOLLMError.safetyRefused
            }
            throw BYOLLMError.decode("gemini: no candidates")
        }
        if candidate.finishReason == "SAFETY" {
            throw BYOLLMError.safetyRefused
        }
        let text = (candidate.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BYOLLMError.decode("gemini: empty completion")
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
            // Gemini returns 400 `API_KEY_INVALID` for a malformed key — treat
            // that as an invalid-key signal rather than a generic bad request.
            if envelope?.error?.status == "INVALID_ARGUMENT",
               (envelope?.error?.message ?? "").localizedCaseInsensitiveContains("api key")
            {
                return .invalidKey
            }
            return .badRequest(envelope?.error?.message ?? "bad request")
        case 500 ... 599:
            return .providerUnavailable
        default:
            return .badRequest(envelope?.error?.message ?? "http \(status)")
        }
    }

    // MARK: - Wire

    private struct GenerateBody: Encodable {
        struct Content: Encodable {
            struct Part: Encodable { let text: String }
            let role: String?
            let parts: [Part]
        }

        let contents: [Content]
        let systemInstruction: Content?
    }

    private static func encodeBody(_ input: LLMChatInput) throws -> Data {
        let systemInstruction: GenerateBody.Content? = {
            guard let system = input.system, !system.isEmpty else { return nil }
            return .init(role: nil, parts: [.init(text: system)])
        }()
        let body = GenerateBody(
            contents: [.init(role: "user", parts: [.init(text: input.userPrompt)])],
            systemInstruction: systemInstruction
        )
        return try JSONEncoder().encode(body)
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }

            let content: Content?
            let finishReason: String?
        }

        struct PromptFeedback: Decodable {
            let blockReason: String?
        }

        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }

    struct ErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }

        let error: ErrorBody?
    }
}
