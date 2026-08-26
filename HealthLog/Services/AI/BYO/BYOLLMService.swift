import Foundation

/// v0.13 W2 — the actor that drives the client-side **device→provider** BYO-key
/// AI path. It is the single consumer-facing seam W4 will call: hand it a
/// composed prompt + a provider, it reads the key from ``BYOKeyStore`` at call
/// time, builds the request via the matching ``LLMProvider`` adapter, performs
/// the (non-streaming) request on a **non-pinned ephemeral** `URLSession`, and
/// returns assistant text.
///
/// **Why an `actor`?** It mirrors ``CoachServerService`` / `OnDeviceBriefingService`:
/// off-MainActor network I/O + buffering, isolated + `Sendable`. No
/// `@unchecked Sendable`, no `assumeIsolated`.
///
/// **Why a non-pinned session?** `APIClient`'s `CertificatePinner` pins *our*
/// domain only. BYO requests go to `api.openai.com` / `api.anthropic.com` /
/// `generativelanguage.googleapis.com` / a user-supplied https host — pinning
/// those is impossible/wrong. We use a fresh `URLSessionConfiguration.ephemeral`
/// session (no pinning delegate, no shared cookie/cache jar) and rely on
/// ATS/TLS. The session is injectable so tests can stub it with
/// `MockURLProtocol`.
///
/// **Key handling:** the key is read from Keychain inside the actor at call
/// time and passed **by value** into the adapter request builder. It never
/// lands on a stored property, never on an adapter, never crosses an
/// `@Observable` boundary. The `generate`/`validate` overloads that take an
/// explicit `key:` (used by W3's pre-save validation, before any key is
/// persisted) take it as a value parameter for exactly the same reason.
public actor BYOLLMService {
    private let session: URLSession
    private let keyStore: BYOKeyStore
    private let adapters: [BYOProviderID: any LLMProvider]
    /// v0.13 W4 — informed-consent gate (Apple 5.1.2(i)). Consulted by the
    /// stored-key ``generate(prompt:provider:)`` BEFORE any network call, so a
    /// BYO request can NEVER fire without an explicit per-provider consent grant.
    /// Production wires this to `AIConsentStore.hasBYOConsent(for:)`; `nil` means
    /// "no gate" (only the W2/W3 pre-save validation path + tests that explicitly
    /// don't exercise consent). The Coach transmit path always wires it.
    private let consentGate: (@Sendable (BYOProviderID) -> Bool)?

    /// - Parameters:
    ///   - keyStore: per-provider key/model/baseURL store (Keychain-backed).
    ///   - session: defaults to a fresh **non-pinned** ephemeral session. Tests
    ///     inject a `MockURLProtocol`-configured session.
    ///   - adapters: provider id → adapter. Defaults to the full v1 set.
    ///   - consentGate: per-provider BYO-consent check. When supplied,
    ///     ``generate(prompt:provider:)`` throws ``BYOLLMError/invalidConfiguration(_:)``
    ///     before any transmission if the gate returns `false` (5.1.2(i)).
    public init(
        keyStore: BYOKeyStore,
        session: URLSession = BYOLLMService.makeDefaultSession(),
        adapters: [BYOProviderID: any LLMProvider] = BYOLLMService.defaultAdapters(),
        consentGate: (@Sendable (BYOProviderID) -> Bool)? = nil
    ) {
        self.keyStore = keyStore
        self.session = session
        self.adapters = adapters
        self.consentGate = consentGate
    }

    /// A fresh ephemeral session with **no** cert-pinning delegate — the 3rd-
    /// party provider hosts are not ours to pin (research §4.7).
    public static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }

    public static func defaultAdapters() -> [BYOProviderID: any LLMProvider] {
        [
            .openAI: OpenAIAdapter(),
            .anthropic: AnthropicAdapter(),
            .gemini: GeminiAdapter(),
            .openAICompatible: OpenAICompatibleAdapter()
        ]
    }

    // MARK: - Consumer API (W4 calls these)

    /// One non-streaming assistant turn, reading the stored key + model +
    /// baseURL for `provider` from the ``BYOKeyStore``. This is the primary
    /// entry point W4's Coach arm calls.
    ///
    /// - Parameters:
    ///   - prompt: the fully-composed prompt from
    ///     `PrivacyFirstPromptBuilder.compose(...)`.
    ///   - provider: which BYO provider to route to.
    /// - Returns: assistant text (Markdown).
    /// - Throws: ``BYOLLMError`` — `.invalidConfiguration` when no key is
    ///   stored, else a typed transport/provider error.
    public func generate(prompt: String, provider: BYOProviderID) async throws -> String {
        // 5.1.2(i) consent gate — assert BEFORE reading the key or touching the
        // wire, so health data can never leave the device without an explicit,
        // current per-provider consent grant. A revoked/absent grant fails
        // closed with `.invalidConfiguration`, never a silent network call.
        if let consentGate, !consentGate(provider) {
            throw BYOLLMError.invalidConfiguration("no BYO consent grant for \(provider.rawValue)")
        }
        guard let key = keyStore.key(for: provider) else {
            throw BYOLLMError.invalidConfiguration("no API key stored for \(provider.rawValue)")
        }
        let input = LLMChatInput(
            userPrompt: prompt,
            model: keyStore.resolvedModel(for: provider)
        )
        return try await generate(
            input: input,
            provider: provider,
            key: key,
            baseURL: keyStore.baseURL(for: provider)
        )
    }

    /// Explicit-parameter overload — used by W3's entry card to run a turn with
    /// a key/model/baseURL that may not be persisted yet. The key is taken by
    /// value and dropped after the request is built.
    public func generate(
        prompt: String,
        provider: BYOProviderID,
        key: String,
        model: String?,
        baseURL: URL?
    ) async throws -> String {
        let input = LLMChatInput(
            userPrompt: prompt,
            model: model ?? provider.defaultModel
        )
        return try await generate(input: input, provider: provider, key: key, baseURL: baseURL)
    }

    /// Cheap key-validity check for W3's "Validate" button. Never throws —
    /// returns a `Result` so the UI renders a green check or a typed error
    /// inline. A `429` is reported as `.failure(.rateLimited)` but the caller
    /// may treat it as "key looks valid, just throttled".
    public func validate(
        provider: BYOProviderID,
        key: String,
        model: String?,
        baseURL: URL?
    ) async -> Result<Void, BYOLLMError> {
        guard let adapter = adapters[provider] else {
            return .failure(.invalidConfiguration("no adapter for \(provider.rawValue)"))
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidConfiguration("empty API key"))
        }
        let request: URLRequest
        do {
            request = try adapter.makeValidationRequest(key: key, model: model, baseURL: baseURL)
        } catch let error as BYOLLMError {
            return .failure(error)
        } catch {
            return .failure(.invalidConfiguration("\(error)"))
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.decode("non-HTTP response"))
            }
            if (200 ... 299).contains(http.statusCode) {
                return .success(())
            }
            return .failure(adapter.mapError(status: http.statusCode, data: data))
        } catch {
            return .failure(.unreachable)
        }
    }

    // MARK: - Core

    private func generate(
        input: LLMChatInput,
        provider: BYOProviderID,
        key: String,
        baseURL: URL?
    ) async throws -> String {
        guard let adapter = adapters[provider] else {
            throw BYOLLMError.invalidConfiguration("no adapter for \(provider.rawValue)")
        }
        let request = try adapter.makeChatRequest(input, key: key, baseURL: baseURL)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as BYOLLMError {
            throw error
        } catch {
            // Transport failure — DNS, offline, TLS, timeout. The key never
            // reaches the log: we surface a typed `.unreachable`, not the
            // underlying `URLError` (which could carry the failing URL).
            throw BYOLLMError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw BYOLLMError.decode("non-HTTP response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw adapter.mapError(status: http.statusCode, data: data)
        }
        return try adapter.parseChat(data, response: http)
    }
}
