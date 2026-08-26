import Foundation

/// v0.13 W2 — generic OpenAI-compatible adapter for any `/v1/chat/completions`
/// endpoint reachable directly from the device (self-hosted gateways,
/// OpenRouter, an https Ollama/LM-Studio front, …).
///
/// Reuses the exact OpenAI wire shape (``OpenAIWire``) — only the host differs,
/// and the host is **user-supplied**. Two hard rules:
/// - The base URL is **required** (no default host to fall back to).
/// - The base URL must be **`https://`** (D9: no app-wide ATS weakening for
///   v1; LAN-`http://` is a later scoped decision). An `http://` base URL is
///   rejected with ``BYOLLMError/invalidConfiguration(_:)`` before any request
///   is built.
///
/// The API key is optional — a keyless local gateway omits the `Authorization`
/// header rather than sending it blank.
public struct OpenAICompatibleAdapter: LLMProvider {
    public let id: BYOProviderID = .openAICompatible

    public init() {}

    public func makeChatRequest(_ input: LLMChatInput, key: String, baseURL: URL?) throws -> URLRequest {
        let base = try Self.validatedBase(baseURL)
        return try OpenAIAdapter.makeChatRequest(input, key: key, base: base)
    }

    public func makeValidationRequest(key: String, model _: String?, baseURL: URL?) throws -> URLRequest {
        let base = try Self.validatedBase(baseURL)
        return try OpenAIAdapter.makeValidationRequest(key: key, base: base)
    }

    public func parseChat(_ data: Data, response _: HTTPURLResponse) throws -> String {
        try OpenAIWire.parseChat(data)
    }

    public func mapError(status: Int, data: Data) -> BYOLLMError {
        OpenAIWire.mapError(status: status, data: data)
    }

    /// Validates the user-supplied base URL: present + `https://`. Rejecting
    /// here (before the request is built) is the https-only gate (D9) — a clear
    /// typed error the W3 entry card can surface inline.
    static func validatedBase(_ baseURL: URL?) throws -> URL {
        guard let baseURL else {
            throw BYOLLMError.invalidConfiguration("missing base URL")
        }
        guard baseURL.scheme?.lowercased() == "https" else {
            throw BYOLLMError.invalidConfiguration("base URL must be https")
        }
        return baseURL
    }

    /// v0.13 WP (L1 hardening) — base-URL gate for the **branded** adapters
    /// (OpenAI / Anthropic / Gemini), which have a fixed https host and only
    /// ever receive `nil` from the live UI. If a future caller passes an
    /// override, it MUST be https — an `http://` override is rejected here
    /// rather than silently weakening the egress. Centralizes the https check so
    /// every adapter shares one gate.
    static func resolvedHTTPSBase(_ override: URL?, default fallback: URL) throws -> URL {
        guard let override else { return fallback }
        return try validatedBase(override)
    }
}
