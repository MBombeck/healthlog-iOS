import Foundation

/// v0.13 W2 — provider-neutral seam for the **client-side, device→provider**
/// BYO-key LLM path (`AIMode.byoKey`). Each concrete adapter
/// (``OpenAIAdapter`` / ``AnthropicAdapter`` / ``GeminiAdapter`` /
/// ``OpenAICompatibleAdapter``) is a pure ``Sendable`` value type: it builds a
/// `URLRequest` for one non-streaming chat completion and parses the response
/// body into plain assistant text. All network I/O is funneled through a single
/// injected `URLSession` inside ``BYOLLMService`` so cert behaviour + tests are
/// uniform — the adapter never touches the wire itself.
///
/// **Security invariants (see research §4):**
/// - The API key is passed **by value** into the request builder at call time;
///   it is never stored on the adapter, never on a property, never on an
///   `@Observable`. It is read from `BYOKeyStore` inside the actor and dropped
///   immediately after the request is built.
/// - The key is sent in a **header**, never in the URL — including Gemini, which
///   uses `x-goog-api-key` rather than `?key=` so the key can never land in a
///   logged `URLRequest.url` (defence-in-depth alongside `LogSanitizer`).
/// - Non-streaming for v1 (D11): one parse path per adapter, correctness-first.
public protocol LLMProvider: Sendable {
    /// The provider identity this adapter serves.
    var id: BYOProviderID { get }

    /// Builds the `URLRequest` for one non-streaming chat completion.
    ///
    /// - Parameters:
    ///   - input: the composed prompt + resolved model + sampling knobs.
    ///   - key: the user's API key, injected by value (never stored).
    ///   - baseURL: required for ``BYOProviderID/openAICompatible`` (must be
    ///     `https://`), ignored by the branded providers (fixed hosts).
    /// - Throws: ``BYOLLMError/badRequest(_:)`` when the input is unusable
    ///   (e.g. a missing/`http://` baseURL for the compatible adapter).
    func makeChatRequest(_ input: LLMChatInput, key: String, baseURL: URL?) throws -> URLRequest

    /// Builds the cheapest request that proves the key works — used by W3's
    /// entry card "Validate" button. Same header-auth + https rules as
    /// ``makeChatRequest(_:key:baseURL:)``.
    func makeValidationRequest(key: String, model: String?, baseURL: URL?) throws -> URLRequest

    /// Parses a successful (2xx) non-streaming JSON body into assistant text.
    /// - Throws: ``BYOLLMError/decode(_:)`` when the body is malformed or empty.
    func parseChat(_ data: Data, response: HTTPURLResponse) throws -> String

    /// Interprets a non-2xx HTTP response into a typed ``BYOLLMError``
    /// (`401/403 → invalidKey`, `429 → rateLimited`, …). Pure function of the
    /// status + body so it is unit-testable without the wire.
    func mapError(status: Int, data: Data) -> BYOLLMError
}

// MARK: - LLMChatInput

/// Provider-neutral input for one chat completion. The `userPrompt` is the
/// fully-composed prompt from `PrivacyFirstPromptBuilder.compose(...)` (system
/// preamble + fenced user text already inside it), so adapters do NOT assemble
/// any prompt scaffolding themselves — they only map it onto the wire shape.
public struct LLMChatInput: Sendable, Equatable {
    /// Optional system preamble routed to the provider's dedicated system slot
    /// (Anthropic `system`, Gemini `systemInstruction`, OpenAI `role:"system"`).
    /// Usually `nil` for v1 — `PrivacyFirstPromptBuilder` already folds the
    /// preamble into `userPrompt`, so the whole composed string travels as the
    /// user turn. Present for callers that want an explicit split.
    public let system: String?
    /// The composed user prompt (snapshot bullets + fenced `<user-input>`).
    public let userPrompt: String
    /// Resolved model identifier (provider default or user override).
    public let model: String
    public let maxTokens: Int
    public let temperature: Double

    public init(
        system: String? = nil,
        userPrompt: String,
        model: String,
        maxTokens: Int = 1024,
        temperature: Double = 0.7
    ) {
        self.system = system
        self.userPrompt = userPrompt
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
