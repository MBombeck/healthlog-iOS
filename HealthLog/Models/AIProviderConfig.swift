import Foundation

/// W-B186 COACH-1 (#24) — origin of the AI provider that can actually serve
/// the user, sent on `GET /api/user/ai-provider` as `managedBy` since server
/// v1.16.16. `"server"` is the previously-`null` admin/operator-managed case:
/// the server holds the key, so the per-user provider fields are empty but the
/// Coach can still answer. Unknown / absent values resolve to ``unknown`` so an
/// older server (no `managedBy`) behaves exactly as before.
///
/// Server thread (#24): *"`managedBy: "user" | "local" | "server" | null` —
/// origin of the serving provider; `"server"` is the previously-`null`
/// admin-managed case … `managedBy === "server"` is the case to mint the
/// consent receipt without requiring a personal key."*
public enum AIManagedBy: String, Sendable, Equatable {
    /// The user's own per-account provider (personal key) serves the request.
    case user
    /// A configured local model (self-hosted base URL) serves it — best-effort
    /// (presence-based, not a liveness guarantee, per the server thread).
    case local
    /// The operator's server/admin-managed key serves it (previously `null`).
    /// No per-user provider is exposed; consent targets a server-managed scope.
    case server
    /// Absent / unknown value — an older server, or a future origin we don't map.
    case unknown

    /// Tolerant parse: `nil` / empty / unrecognised → ``unknown`` so an older
    /// server (the field absent) behaves exactly as before COACH-1.
    static func fromWire(_ raw: String?) -> AIManagedBy {
        guard let raw, !raw.isEmpty else { return .unknown }
        return AIManagedBy(rawValue: raw) ?? .unknown
    }
}

/// The consent identity iOS must use for server-side AI.
///
/// The server's `aiAvailable` flag is authoritative when present. A concrete
/// provider keeps its provider-specific consent receipt; an available provider
/// unknown to this client uses the provider-opaque receipt so adding a new
/// server provider cannot silently hide the Coach on older app builds.
public enum AIConsentTarget: Sendable, Equatable {
    case unavailable
    case provider(AIProvider)
    case providerOpaque
}

/// Decoded shape of `GET /api/user/ai-provider` (server route:
/// `src/app/api/user/ai-provider/route.ts:13-43`). All fields are optional
/// because a fresh user has none of them set.
///
/// The encrypted API keys themselves are **never** returned by the server —
/// only their last-4-character preview (`"...XXXX"`) plus the `hasXKey`
/// boolean flag are exposed for the configured-or-not affordance.
///
/// **W-B186 COACH-1 (#24):** server v1.16.16 added `aiAvailable` + `managedBy`
/// so the Coach can be shown whenever a provider can actually serve the user —
/// including the admin/server-managed case where the per-user `provider` field
/// is `null`. Both are optional/tolerant: an older server omits them and the
/// pre-COACH-1 behaviour is preserved (`aiAvailableResolved == nil`,
/// `managedByResolved == .unknown`).
public struct AIProviderConfig: Codable, Sendable, Equatable {
    public let provider: String?
    public let model: String?
    public let baseUrl: String?
    public let hasAnthropicKey: Bool
    public let anthropicKeyPreview: String?
    public let hasOpenaiKey: Bool
    public let openaiKeyPreview: String?
    public let hasLocalKey: Bool

    /// W-B186 COACH-1 — `true` when ANY provider can answer (personal key,
    /// local model, OR the operator's server/admin-managed key). `nil` on an
    /// older server that doesn't send the field — callers MUST treat `nil` as
    /// "unknown, fall back to the per-provider resolution" so legacy servers
    /// behave exactly as before.
    public let aiAvailable: Bool?

    /// W-B186 COACH-1 — raw `managedBy` wire value (`"user"|"local"|"server"`).
    /// Decoded via ``managedByResolved``; kept raw here for `Codable` round-trip.
    public let managedBy: String?

    public init(
        provider: String? = nil,
        model: String? = nil,
        baseUrl: String? = nil,
        hasAnthropicKey: Bool = false,
        anthropicKeyPreview: String? = nil,
        hasOpenaiKey: Bool = false,
        openaiKeyPreview: String? = nil,
        hasLocalKey: Bool = false,
        aiAvailable: Bool? = nil,
        managedBy: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.baseUrl = baseUrl
        self.hasAnthropicKey = hasAnthropicKey
        self.anthropicKeyPreview = anthropicKeyPreview
        self.hasOpenaiKey = hasOpenaiKey
        self.openaiKeyPreview = openaiKeyPreview
        self.hasLocalKey = hasLocalKey
        self.aiAvailable = aiAvailable
        self.managedBy = managedBy
    }

    /// Maps the wire provider field through `AIProvider.fromWire`. Falls back
    /// to `.unconfigured` for nil/empty/unknown — UI never sees a phantom
    /// value (M2-A3 §2.1 root-cause).
    public var resolvedProvider: AIProvider {
        AIProvider.fromWire(provider) ?? .unconfigured
    }

    // MARK: - W-B186 COACH-1 (#24) — effective AI availability

    /// The decoded `managedBy` origin. ``AIManagedBy/unknown`` on an older
    /// server (field absent) so the pre-COACH-1 per-provider path is taken.
    public var managedByResolved: AIManagedBy {
        AIManagedBy.fromWire(managedBy)
    }

    /// W-B186 COACH-1 — the server's effective-availability boolean, or `nil`
    /// when the server doesn't send it (older deployment). Callers gate Coach
    /// visibility on this **only when present**; `nil` means "unknown, use the
    /// legacy per-provider resolution" so a pre-1.16.16 server is unchanged.
    public var aiAvailableResolved: Bool? {
        aiAvailable
    }

    /// Single source of truth for every server-side AI gate. `managedBy`
    /// describes ownership for UI/copy; it never acts as a provider allowlist.
    /// An explicit `aiAvailable == false` always wins, including when a stale
    /// concrete provider value is also present. Older servers without the flag
    /// retain the legacy concrete-provider behavior.
    public var aiConsentTarget: AIConsentTarget {
        if aiAvailable == false {
            return .unavailable
        }
        if resolvedProvider != .unconfigured {
            return .provider(resolvedProvider)
        }
        if aiAvailable == true {
            return .providerOpaque
        }
        return .unavailable
    }

    /// `true` when the server can provide AI but its provider does not map to a
    /// concrete provider understood by this client. The persisted receipt keeps
    /// its historical server-managed key for migration compatibility.
    public var usesProviderOpaqueAIConsent: Bool {
        aiConsentTarget == .providerOpaque
    }

    /// Effective availability used by provider-agnostic UI affordances.
    public var isServerAIAvailable: Bool {
        aiConsentTarget != .unavailable
    }

    /// W-B186 COACH-1 — `true` only when the server explicitly reports NO
    /// provider can serve the user (`aiAvailable == false`). This is the sole
    /// case where the Coach stays genuinely hidden. `nil`/absent is NOT this —
    /// an older server falls through to the legacy per-provider resolution.
    public var isAIExplicitlyUnavailable: Bool {
        aiAvailable == false
    }

    /// `true` when the resolved provider has everything it needs to actually
    /// run on the server side. Drives the "Konfiguriert" / "Nicht konfiguriert"
    /// badge per M2-A3 §"Konfiguriert / Nicht konfiguriert badge based on real state".
    public var isFullyConfigured: Bool {
        // Newer servers already performed the provider-specific readiness
        // check. Trust that result even when the wire provider is newer than
        // this client; otherwise Settings would claim "Not configured" while
        // the same response says the Coach is available.
        if let aiAvailable {
            return aiAvailable
        }
        return switch resolvedProvider {
        case .unconfigured: false
        case .anthropic: hasAnthropicKey
        case .openai: hasOpenaiKey
        case .local: hasLocalKey && baseUrl?.isEmpty == false
        // CU-16 — the base URL + key of an OpenAI-compatible endpoint live in
        // server columns iOS never reads (there is no `hasOpenaiCompatibleKey`
        // flag). The server having SELECTED this provider is the only signal we
        // have; painting "Nicht konfiguriert" over it would assert a defect we
        // cannot see.
        case .openaiCompatible: true
        }
    }

    /// Preview snippet (e.g. `"...AB12"`) for the currently-selected provider.
    /// `nil` when no key is set.
    public var activeKeyPreview: String? {
        switch resolvedProvider {
        case .anthropic: anthropicKeyPreview
        case .openai: openaiKeyPreview
        case .local: hasLocalKey ? "•••" : nil
        // `.openaiCompatible` has no preview field on the wire — no key is
        // shown rather than borrowing OpenAI's, which would be a different key.
        case .unconfigured, .openaiCompatible: nil
        }
    }
}

/// Body shape for `PATCH /api/user/ai-provider`. Every field is optional —
/// the server only updates the fields you send (partial-update semantics,
/// per route.ts:46-127). Sending `nil`/empty for a string field clears it
/// server-side (route.ts:54-72).
///
/// **Idempotency:** `APIClient.send` already supplies an Idempotency-Key for
/// every PATCH; no caller action required.
public struct AIProviderUpdate: Encodable, Sendable {
    public var provider: String??
    public var model: String??
    public var baseUrl: String??
    public var anthropicKey: String??
    public var openaiKey: String??
    public var localKey: String??

    public init(
        provider: String?? = nil,
        model: String?? = nil,
        baseUrl: String?? = nil,
        anthropicKey: String?? = nil,
        openaiKey: String?? = nil,
        localKey: String?? = nil
    ) {
        self.provider = provider
        self.model = model
        self.baseUrl = baseUrl
        self.anthropicKey = anthropicKey
        self.openaiKey = openaiKey
        self.localKey = localKey
    }

    /// Convenience: produce a body that only changes the active provider.
    /// Passes `null` (server clears) for `.unconfigured`.
    public static func setProvider(_ provider: AIProvider) -> AIProviderUpdate {
        .init(provider: .some(provider.wireValue))
    }

    /// Custom encoding — `String??` lets us distinguish three states:
    ///   `nil`             → field absent (no change requested)
    ///   `.some(nil)`      → field present, value `null` → server clears
    ///   `.some(.some(v))` → field present with value `v` → server writes
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodeNullableField(provider, into: &container, key: .provider)
        try Self.encodeNullableField(model, into: &container, key: .model)
        try Self.encodeNullableField(baseUrl, into: &container, key: .baseUrl)
        try Self.encodeNullableField(anthropicKey, into: &container, key: .anthropicKey)
        try Self.encodeNullableField(openaiKey, into: &container, key: .openaiKey)
        try Self.encodeNullableField(localKey, into: &container, key: .localKey)
    }

    private static func encodeNullableField(
        _ value: String??,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        switch value {
        case .none:
            // No-op — skip the key entirely so the server doesn't see it.
            break
        case let .some(inner):
            if let inner {
                try container.encode(inner, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, baseUrl, anthropicKey, openaiKey, localKey
    }
}
