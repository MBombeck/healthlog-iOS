import Foundation

// MARK: - DashboardBriefingState

/// Briefing lifecycle state on `GET /api/dashboard/snapshot` (server
/// `src/lib/dashboard/snapshot.ts` `BriefingState`).
///
/// **v1.16.x tolerant-first decode (GH issue #15):** the server enum grew
/// `no-provider` in v1.16.0 and may grow further values. A strict
/// `String`-raw enum would throw `DecodingError.dataCorrupted` on the first
/// unknown value and poison the WHOLE snapshot decode — so unknown raw
/// values map to ``unknown(_:)`` instead of failing. The original raw string
/// is retained for logging/diagnostics only; render paths treat `.unknown`
/// like "no usable signal" (deterministic fallback, never a spinner).
public enum DashboardBriefingState: Codable, Sendable, Hashable {
    /// Fresh cached briefing delivered in `briefing`.
    case ready
    /// Cache stale/missing but a provider is configured — a warm pass will
    /// refill it. May still carry the LAST briefing via `briefingStale`.
    case preparing
    /// Coach/briefing feature disabled for this account.
    case disabled
    /// v1.16.0 — stale-or-missing cache AND no AI provider configured
    /// anywhere, so no warm pass will ever fill it. Clients stop waiting:
    /// render the deterministic fallback prose, never a "preparing" state.
    case noProvider
    /// Forward-compat arm: any raw value this client does not know yet.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "ready": self = .ready
        case "preparing": self = .preparing
        case "disabled": self = .disabled
        case "no-provider": self = .noProvider
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .ready: "ready"
        case .preparing: "preparing"
        case .disabled: "disabled"
        case .noProvider: "no-provider"
        case let .unknown(raw): raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - DashboardSnapshotBriefing

/// Thin, tolerant projection of the briefing slot on the
/// `GET /api/dashboard/snapshot` payload (server v1.7.0+, fields per
/// `docs/api/openapi.yaml` `DashboardSnapshot`). Decodes ONLY the four
/// briefing fields — the rest of the snapshot (tiles / extras /
/// layoutCatalogue / metricStates) is ignored by `Codable`, so an unrelated
/// snapshot schema change can never break this read.
///
/// **v1.16.x additive contract (GH issue #15):**
/// - `briefingState` decodes tolerantly (see ``DashboardBriefingState``).
/// - `briefingStale` (required since v1.15.20) decodes with a `false`
///   default so the same DTO works against ≤v1.15.19 servers.
/// - When `briefingStale == true`, `briefing` carries the LAST generated
///   briefing and `briefingUpdatedAt` its generation instant — render that
///   text with its timestamp instead of a "preparing" state.
///
/// **v1.27.7 additive (`scoreRings`):** the same snapshot payload gained the
/// user-selected hero score rings (`scoreRings[]`, server-resolved for TODAY,
/// selection-ordered). Decoded tolerantly — absent (older server) or an
/// unparseable element degrades to `[]`, never failing the snapshot read.
public struct DashboardSnapshotBriefing: Codable, Sendable, Hashable {
    /// Cached daily briefing (same `DailyBriefing` shape the generate
    /// endpoint emits). `nil` when nothing usable is cached.
    public let briefing: DailyBriefing?
    public let briefingState: DashboardBriefingState
    /// Generation instant of `briefing` (ISO8601 on the wire). `nil` when no
    /// briefing was ever generated.
    public let briefingUpdatedAt: Date?
    /// `true` when `briefing` is the last good (expired-TTL) briefing while a
    /// refresh is pending (`preparing`) or impossible (`no-provider`).
    public let briefingStale: Bool
    /// **v1.27.7** — the user-selected hero score rings the server resolved for
    /// TODAY, in selection order. Only rings WITH data appear; a missing entry
    /// means no data or a disabled module (never zero). Empty on older servers
    /// (field absent) — the hero self-suppresses.
    public let scoreRings: [DashboardScoreRing]
    /// **v1.34.0** — the rebuilt composite Health Score. This snapshot slot is
    /// the ONLY wire that carries the flat, client-shaped score DTO; the
    /// `/api/analytics` `healthScore` field became the server's internal
    /// `HealthScoreReport` in the same release and no longer decodes here.
    ///
    /// `null` when the rollup coverage is cold or the composite is not `ok` —
    /// an honest "no score yet", never a zero.
    public let healthScore: HealthScore?

    public init(
        briefing: DailyBriefing? = nil,
        briefingState: DashboardBriefingState,
        briefingUpdatedAt: Date? = nil,
        briefingStale: Bool = false,
        scoreRings: [DashboardScoreRing] = [],
        healthScore: HealthScore? = nil
    ) {
        self.briefing = briefing
        self.briefingState = briefingState
        self.briefingUpdatedAt = briefingUpdatedAt
        self.briefingStale = briefingStale
        self.scoreRings = scoreRings
        self.healthScore = healthScore
    }

    private enum CodingKeys: String, CodingKey {
        case briefing, briefingState, briefingUpdatedAt, briefingStale, scoreRings, healthScore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The briefing object itself is tolerant: a shape this client can't
        // parse degrades to nil (render falls back deterministically) instead
        // of failing the snapshot — the cached text is server-free-form.
        briefing = try? c.decodeIfPresent(DailyBriefing.self, forKey: .briefing)
        // Absent state (pre-v1.7.0 caches) maps to the unknown arm — render
        // paths treat it like "no usable signal", never a spinner.
        briefingState = try c.decodeIfPresent(DashboardBriefingState.self, forKey: .briefingState)
            ?? .unknown("")
        briefingUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .briefingUpdatedAt)
        // Compat ≤v1.15.19: field absent → false (never stale).
        briefingStale = try c.decodeIfPresent(Bool.self, forKey: .briefingStale) ?? false
        // v1.27.7 — tolerant, lossy ring decode. Absent field → []; an element
        // whose id is outside this client's closed set is skipped (never fails
        // the whole array). Selection order is preserved for the survivors.
        if let rows = try? c.decodeIfPresent([DashboardScoreRing.SkipUnknown].self, forKey: .scoreRings) {
            scoreRings = rows.compactMap(\.ring)
        } else {
            scoreRings = []
        }
        // v1.34.0 — the composite score. Tolerant: `null` (cold coverage), an
        // absent field (older server) and a shape this client cannot parse all
        // degrade to nil, so the score never poisons the snapshot read.
        healthScore = try? c.decodeIfPresent(HealthScore.self, forKey: .healthScore)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(briefing, forKey: .briefing)
        try c.encode(briefingState, forKey: .briefingState)
        try c.encodeIfPresent(briefingUpdatedAt, forKey: .briefingUpdatedAt)
        try c.encode(briefingStale, forKey: .briefingStale)
        try c.encode(scoreRings, forKey: .scoreRings)
        try c.encodeIfPresent(healthScore, forKey: .healthScore)
    }
}

// MARK: - Render policy

/// What the briefing surface should paint for a given snapshot slot. Pure
/// reducer (unit-tested) so every consumer agrees on the same branch order.
public enum DashboardBriefingRenderPolicy: Equatable, Sendable {
    /// Render the briefing prose. `stale == true` → show the small
    /// "Stand HH:MM" caption from `asOf` (the briefingStale honesty
    /// contract) instead of any preparing state.
    case prose(DailyBriefing, asOf: Date?, stale: Bool)
    /// No server prose and none will come (`no-provider`, unknown states,
    /// or a `ready`/`preparing` slot without content the client can use) —
    /// render the deterministic local fallback (the b155 A3
    /// period-narrative / Statistik-Mode path). NEVER a spinner.
    case deterministicFallback
    /// Provider configured, warm pass in flight, nothing cached yet — a calm
    /// preparing hint is honest here (content IS coming).
    case preparing
    /// Feature disabled for the account — render nothing.
    case hidden
}

public extension DashboardSnapshotBriefing {
    /// Canonical state→render mapping. Branch order is the contract:
    /// 1. A stale-but-delivered briefing ALWAYS renders (with timestamp) —
    ///    it beats both `preparing` and `no-provider`.
    /// 2. `ready` with content renders fresh prose.
    /// 3. `disabled` hides the surface.
    /// 4. `no-provider` + every unknown/contentless state degrades to the
    ///    deterministic fallback — never a spinner the server can't resolve.
    /// 5. Only `preparing` without stale content shows a preparing hint.
    var renderPolicy: DashboardBriefingRenderPolicy {
        if briefingStale, let briefing {
            return .prose(briefing, asOf: briefingUpdatedAt, stale: true)
        }
        switch briefingState {
        case .ready:
            guard let briefing else { return .deterministicFallback }
            return .prose(briefing, asOf: briefingUpdatedAt, stale: false)
        case .disabled:
            return .hidden
        case .noProvider, .unknown:
            return .deterministicFallback
        case .preparing:
            return .preparing
        }
    }

    /// The briefing a surface may paint as prose right now (fresh or stale),
    /// `nil` otherwise. Convenience over ``renderPolicy`` for callers that
    /// only need the content arm.
    var deliverableBriefing: DailyBriefing? {
        if case let .prose(briefing, _, _) = renderPolicy { return briefing }
        return nil
    }
}
