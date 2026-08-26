import Foundation

/// v0.13 W2 — typed error surface shared across every BYO adapter +
/// ``BYOLLMService``. Adapters map provider HTTP errors onto these cases via
/// ``LLMProvider/mapError(status:data:)``; the Coach consumer (W4) folds them
/// into its existing `LocalLLMError` banner so no new view-layer error type is
/// needed.
///
/// `Equatable` so the adapter unit-tests can assert exact mappings
/// (`401 → .invalidKey`, `429 → .rateLimited`, malformed → `.decode`).
public enum BYOLLMError: Error, Sendable, Equatable {
    /// `401` / `403` — the API key is missing, malformed, or rejected.
    case invalidKey
    /// `429` — provider rate limit hit. The key itself looks valid.
    case rateLimited
    /// `402` or provider-specific — billing quota exhausted.
    case quotaExhausted
    /// `404` on the model route — the requested model id is unknown.
    case modelNotFound
    /// `400` — malformed request (e.g. context too long). Carries a short,
    /// already-sanitised provider hint (never the key — adapters pass only the
    /// provider's own error `message`/`type`, which never contains the key).
    case badRequest(String)
    /// `5xx` — the provider is temporarily unavailable.
    case providerUnavailable
    /// Transport failure — DNS, offline, TLS, timeout.
    case unreachable
    /// Body could not be parsed (non-UTF8, missing fields, empty completion).
    case decode(String)
    /// Provider content filter refused to answer.
    case safetyRefused
    /// The caller supplied an invalid configuration before any request was made
    /// (missing baseURL, `http://` baseURL for the https-only compatible
    /// adapter, empty key). Distinct from ``badRequest(_:)`` which is a
    /// provider-side 400.
    case invalidConfiguration(String)

    /// v0.13 WP (L2 hardening) — a log-safe label that NEVER carries the
    /// free-form provider ``badRequest`` payload. `LogSanitizer` redacts
    /// keys/emails/UUIDs/tokens but not bare vital numbers, and a provider 400
    /// *could* echo a fragment of the offending request. Use this — not
    /// `String(describing:)` — in any logged BYO-error line so the raw provider
    /// message never reaches the log.
    public var loggableDescription: String {
        switch self {
        case .invalidKey: "invalidKey"
        case .rateLimited: "rateLimited"
        case .quotaExhausted: "quotaExhausted"
        case .modelNotFound: "modelNotFound"
        case .badRequest: "badRequest"
        case .providerUnavailable: "providerUnavailable"
        case .unreachable: "unreachable"
        case .decode: "decode"
        case .safetyRefused: "safetyRefused"
        case .invalidConfiguration: "invalidConfiguration"
        }
    }
}
