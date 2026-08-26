import Foundation

/// v0.13 — the BYO-key ("bring your own") LLM provider identity for the
/// **client-side, device→provider** AI path (`AIMode.byoKey`).
///
/// Deliberately distinct from the server-side ``AIProvider`` enum: the server
/// path (`AIMode.online`) only knows `anthropic` / `openai` / a generic
/// `local` relay, and its keys live on the server. The BYO path needs its own
/// provider set — notably **Gemini** and a **generic OpenAI-compatible**
/// endpoint — and stores the key in the device Keychain, never on the server.
///
/// The `rawValue` is a STABLE persistence token: it keys both the per-provider
/// consent grant (`AIConsentStore.byoKeyPrefix + rawValue`) and the Keychain
/// API-key entry (`BYOKeyStore`, v0.13 W2). Do not rename existing raws.
public enum BYOProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAI = "openai"
    case anthropic
    case gemini
    /// Any OpenAI-compatible `/chat/completions` endpoint reachable directly
    /// from the device over **https** (e.g. a self-hosted gateway). The LAN
    /// cleartext `http://` case (Ollama default) is intentionally a later
    /// scoped-ATS decision — see `.planning/v013-standalone/DECISIONS.md` D9.
    case openAICompatible = "openaiCompatible"

    public var id: String {
        rawValue
    }

    /// Human-facing provider name. Not localized — these are brand names.
    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    /// The default model identifier used when the user does not override it.
    /// Cheap, fast, widely-available defaults — the user can override via the
    /// free-form model field (W3). Kept here so the model picker and the
    /// request adapters (W2) read one source of truth.
    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-3-5-haiku-latest"
        case .gemini: "gemini-1.5-flash"
        case .openAICompatible: "gpt-4o-mini"
        }
    }

    /// Whether this provider needs a user-supplied base URL (the generic
    /// OpenAI-compatible endpoint does; the branded providers have fixed hosts).
    public var requiresBaseURL: Bool {
        self == .openAICompatible
    }
}
