import Foundation

public struct Insight: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let body: String?
    public let severity: InsightSeverity
    public let recommendations: [InsightRecommendation]
    public let generatedAt: Date
    /// Server (`/api/insights/cards`) sends a free-form provider string —
    /// the service may return provider and model-family identifiers that are
    /// wider than the app's configurable-provider enum. Decoding it as the narrow
    /// `AIProvider` enum threw the entire array on first unknown value
    /// (W2a-A2 Audit §2.4). We now keep the raw string and surface a
    /// best-effort label via `providerLabel`.
    public let provider: String

    public init(
        id: String,
        title: String,
        summary: String,
        body: String? = nil,
        severity: InsightSeverity,
        recommendations: [InsightRecommendation] = [],
        generatedAt: Date,
        provider: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.body = body
        self.severity = severity
        self.recommendations = recommendations
        self.generatedAt = generatedAt
        self.provider = provider
    }
}

public extension Insight {
    /// Best-effort UI-Label für den Provider-Badge. Maps the wide server
    /// vocabulary onto a user-friendly family label whenever we recognise
    /// it, and falls back to a tidied raw string otherwise.
    ///
    /// The family labels are plain strings so Insight cards can tolerate wider
    /// provider/model identifiers without coupling to the configuration enum.
    var providerLabel: String {
        let key = provider.lowercased()
        if key.contains("anthropic") || key.contains("claude") { return "Anthropic" }
        if key.contains("gpt") || key.contains("openai") { return "OpenAI" }
        if key.contains("gemini") || key.contains("google") { return "Gemini" }
        // Replace separators so unknown model-family identifiers read cleanly.
        let cleaned = provider
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return cleaned.capitalized
    }
}

public enum InsightSeverity: String, Codable, Sendable {
    case info
    case good
    case caution
    case alert
}

public struct InsightRecommendation: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let label: String
    public let actionURL: URL?
}

/// User-configurable AI provider, mirrored exactly to the server's wire enum
/// (`OPENAI | ANTHROPIC | LOCAL | OPENAI_COMPATIBLE`).
///
/// The enum mirrors only provider modes that iOS can safely render. It also
/// includes a synthetic `.unconfigured` UI state for the
/// nothing-yet picker affordance — `.unconfigured` never leaves the device,
/// it maps to a `PATCH { provider: null }` clear when the user picks it.
public enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// User has no provider configured. UI-only sentinel — never sent on the wire.
    case unconfigured
    case anthropic
    case openai
    case local
    /// CU-16 (A6) — server v1.34: any OpenAI-compatible `/chat/completions`
    /// endpoint the SERVER holds credentials for (base URL + key live in the
    /// server's own columns). Added so a `GET /api/user/ai-provider` carrying
    /// `OPENAI_COMPATIBLE` resolves to itself instead of collapsing onto
    /// ``unconfigured`` — which would have painted "Nicht konfiguriert" over a
    /// provider that is demonstrably serving the user.
    ///
    /// **Not iOS-configurable** (absent from ``configurableCases``), same
    /// The endpoint is an operator concern and iOS has no field for it, so
    /// exposing a half-working picker row would be
    /// a Baustelle (AC18). Decode-and-display only.
    ///
    /// Distinct from ``BYOProviderID/openAICompatible``, which is the
    /// device→provider path with the key in the local Keychain.
    case openaiCompatible

    public var id: String {
        rawValue
    }

    /// Server wire value. `.unconfigured` deliberately maps to `nil` so the
    /// PATCH body sends `provider: null` (server clears the column).
    public var wireValue: String? {
        switch self {
        case .unconfigured: nil
        case .anthropic: "ANTHROPIC"
        case .openai: "OPENAI"
        case .local: "LOCAL"
        case .openaiCompatible: "OPENAI_COMPATIBLE"
        }
    }

    /// Parses the server-wire value back into the iOS enum. `nil` is treated
    /// as `.unconfigured`. Returns `nil` for genuinely unknown providers so
    /// callers can decide whether to fall back or surface as error.
    public static func fromWire(_ raw: String?) -> AIProvider? {
        guard let raw, !raw.isEmpty else { return .unconfigured }
        switch raw {
        case "ANTHROPIC": return .anthropic
        case "OPENAI": return .openai
        case "LOCAL": return .local
        case "OPENAI_COMPATIBLE": return .openaiCompatible
        default: return nil
        }
    }

    /// All real (non-sentinel) provider cases — the three the user can
    /// configure today. `.openaiCompatible` is intentionally absent: it
    /// decodes for forward compatibility, but has no configure-and-save flow
    /// on iOS — the endpoint's base URL + key are the operator's,
    /// held server-side with no iOS field behind them. Per AC18 —
    /// selectable-but-stub picker options count as Baustelle.
    public static var configurableCases: [AIProvider] {
        [.anthropic, .openai, .local]
    }

    public var label: String {
        switch self {
        case .unconfigured: String(localized: "Not configured", comment: "AI-Provider — no provider chosen")
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .local: String(localized: "Local (Ollama / LM Studio)", comment: "AI-Provider — local Ollama / LM Studio")
        case .openaiCompatible: String(localized: "insight.provider.openaiCompatible")
        }
    }

    /// One-line description shown under each picker row.
    public var subtitle: String {
        switch self {
        case .unconfigured: String(localized: "No assistant provider is being used.")
        case .anthropic: String(localized: "API key from console.anthropic.com")
        case .openai: String(localized: "API key from platform.openai.com")
        case .local: String(localized: "Your own Ollama or LM Studio instance on the network.")
        // Deliberately names no vendor: an OpenAI-compatible endpoint can be
        // anyone's. Claiming a company here would be an invention.
        case .openaiCompatible: String(localized: "An OpenAI-compatible endpoint configured on your server.")
        }
    }

    /// SF Symbol shown alongside the provider in the picker.
    public var iconName: String {
        switch self {
        case .unconfigured: "questionmark.circle"
        case .anthropic: "sparkles"
        case .openai: "circle.hexagongrid.fill"
        case .local: "server.rack"
        case .openaiCompatible: "network"
        }
    }

    /// Whether the provider stores its API key on the server.
    public var requiresKey: Bool {
        switch self {
        case .anthropic, .openai, .local: true
        // `.openaiCompatible` DOES take a key server-side, but iOS never
        // renders a field for it (not in `configurableCases`), so answering
        // `true` would only unlock a clear-key affordance for a key we cannot
        // address. `false` = "iOS has no key to manage here".
        case .unconfigured, .openaiCompatible: false
        }
    }

    /// Whether **iOS** offers a `baseUrl` field for the provider (LOCAL only).
    /// Per server `route.ts:73-91` the column is shared across providers;
    /// `OPENAI_COMPATIBLE` also uses it, but that endpoint is operator-owned
    /// and not iOS-configurable — so iOS renders no field and must not send
    /// one.
    public var supportsBaseUrl: Bool {
        self == .local
    }

    /// Whether the provider accepts a free-form model-name override.
    public var supportsModelOverride: Bool {
        switch self {
        case .anthropic, .openai, .local: true
        case .unconfigured, .openaiCompatible: false
        }
    }
}

public struct CorrelationFinding: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let leftMetric: String
    public let rightMetric: String
    public let coefficient: Double
    public let sampleSize: Int
}
