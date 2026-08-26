import Foundation

// MARK: - AIInsightResponse

/// Comprehensive insight payload returned by `GET /api/insights/comprehensive`.
///
/// **Schema-Drift note (v0.3.0 hotfix):** The W2b-A4 model was designed
/// against a Zod schema (`summary`, `recommendations`, `citations`, …)
/// that the production server does **not** emit. The real comprehensive
/// route returns a metric digest envelope (`summaries`, `bmi`, `alerts`,
/// `medications`, …) without any of these AI-shaped fields.
///
/// Until a true AI-comprehensive endpoint exists, every field below is
/// optional/defaulted so decoding the real server payload succeeds with
/// an empty value rather than throwing. The InsightsStore now also pulls
/// `/api/insights/cards` for the actual card list rendered on the screen.
///
/// Every field is `Sendable` + value-typed so it crosses actor boundaries safely.
public struct AIInsightResponse: Codable, Sendable, Hashable {
    public let summary: String?
    public let recommendations: [Recommendation]
    public let citations: [Citation]
    public let warnings: [InsightWarning]
    public let dailyBriefing: DailyBriefing?
    public let promptVersion: String?
    /// Provider identifier as a free-form string. The server emits a wide
    /// vocabulary (`anthropic`, `claude_haiku`, `gpt_4o_mini`, `local`, …) —
    /// we keep it untyped (W2a-A2 fix `25706d0`) and surface a friendly
    /// label via `AIInsightResponse.providerLabel` only when consumed by UI.
    public let provider: String?
    /// v0.4.0 Stream Golf — the production `/api/insights/comprehensive`
    /// envelope rides metric-digest fields (`summaries`, `bmi`, `alerts`, the
    /// four correlation matrices, …) alongside the AI-shaped fields above.
    /// Until v0.4.0 the decoder silently discarded every digest field;
    /// `digest` captures them all (Optional / nullable-tolerant).
    ///
    /// Decode-strategy: the digest is parsed from the **same** root keyed
    /// container — server emits a flat envelope, not nested. See A8 §4.
    public let digest: ComprehensiveDigest?

    public init(
        summary: String? = nil,
        recommendations: [Recommendation] = [],
        citations: [Citation] = [],
        warnings: [InsightWarning] = [],
        dailyBriefing: DailyBriefing? = nil,
        promptVersion: String? = nil,
        provider: String? = nil,
        digest: ComprehensiveDigest? = nil
    ) {
        self.summary = summary
        self.recommendations = recommendations
        self.citations = citations
        self.warnings = warnings
        self.dailyBriefing = dailyBriefing
        self.promptVersion = promptVersion
        self.provider = provider
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case recommendations
        case citations
        case warnings
        case dailyBriefing
        case promptVersion
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        recommendations = try container.decodeIfPresent([Recommendation].self, forKey: .recommendations) ?? []
        citations = try container.decodeIfPresent([Citation].self, forKey: .citations) ?? []
        warnings = try container.decodeIfPresent([InsightWarning].self, forKey: .warnings) ?? []
        dailyBriefing = try container.decodeIfPresent(DailyBriefing.self, forKey: .dailyBriefing)
        promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        // The digest fields sit at the SAME root level as the AI-shaped fields.
        // Decode the whole root into ComprehensiveDigest — every digest field is
        // Optional so the parse succeeds even on minimal/AI-only payloads. The
        // helper `digestIfNonEmpty` collapses an empty digest to `nil` so UI
        // sites can switch on `.digest == nil` instead of inspecting fields.
        let candidate = try? ComprehensiveDigest(from: decoder)
        digest = candidate?.nonEmpty
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(recommendations, forKey: .recommendations)
        try container.encode(citations, forKey: .citations)
        try container.encode(warnings, forKey: .warnings)
        try container.encodeIfPresent(dailyBriefing, forKey: .dailyBriefing)
        try container.encodeIfPresent(promptVersion, forKey: .promptVersion)
        try container.encodeIfPresent(provider, forKey: .provider)
        // Encode digest into the same root container if present.
        if let digest {
            try digest.encode(to: encoder)
        }
    }
}

public extension AIInsightResponse {
    /// Reuses the `Insight.providerLabel` mapper so the same
    /// The provider-family table applies to comprehensive responses.
    var providerLabel: String? {
        guard let provider, !provider.isEmpty else { return nil }
        return Insight(
            id: "_",
            title: "_",
            summary: "_",
            body: nil,
            severity: .info,
            recommendations: [],
            generatedAt: Date(),
            provider: provider
        ).providerLabel
    }
}

// MARK: - Recommendation

public struct Recommendation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let severity: RecommendationSeverity
    public let metricSource: MetricSource
    public let rationale: Rationale?

    public init(
        id: String,
        text: String,
        severity: RecommendationSeverity,
        metricSource: MetricSource,
        rationale: Rationale? = nil
    ) {
        self.id = id
        self.text = text
        self.severity = severity
        self.metricSource = metricSource
        self.rationale = rationale
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, severity, metricSource, rationale
    }

    // Server emits `recommendations` as a Zod union — plain String OR
    // structured object with every UI-required field optional
    // (`src/lib/ai/types.ts:54-78` insightRecommendationSchema).
    //
    // **v0.7.0 W-API-RENDER fix.** Prior shape wrapped every per-field
    // decode in `try?` and fell back to an empty/sentinel value. Schema
    // drift (renamed field, type mismatch on `severity`, missing
    // `metricSource`) produced silently-empty cards instead of a
    // decoding error that the surrounding fetch could surface. Typed
    // decoding now throws when the wire shape diverges from contract —
    // string-fallback path (the legitimate union half) stays intact;
    // the missing fields use `decodeIfPresent` so server-omitted
    // optionals don't trip the throw. Schema drift = visible error.
    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            id = UUID().uuidString
            text = raw
            severity = .info
            metricSource = MetricSource(type: "", timeRange: "", summary: "")
            rationale = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        severity = try container.decodeIfPresent(RecommendationSeverity.self, forKey: .severity) ?? .info
        metricSource = try container.decodeIfPresent(MetricSource.self, forKey: .metricSource)
            ?? MetricSource(type: "", timeRange: "", summary: "")
        rationale = try container.decodeIfPresent(Rationale.self, forKey: .rationale)
    }
}

/// Lowercase EN tokens — see `08-locked-contracts.md §9.1` (GROUND RULE 11).
/// The UI translates at render time via `Localizable.xcstrings`; never
/// localise on-wire.
public enum RecommendationSeverity: String, Codable, Sendable, CaseIterable {
    case info
    case suggestion
    case important
    case urgent

    /// Sort key (info < suggestion < important < urgent).
    public var sortRank: Int {
        switch self {
        case .info: 0
        case .suggestion: 1
        case .important: 2
        case .urgent: 3
        }
    }
}

public struct Rationale: Codable, Sendable, Hashable {
    public let dataWindow: String?
    public let comparedTo: String?
    public let deviation: String?

    public init(dataWindow: String? = nil, comparedTo: String? = nil, deviation: String? = nil) {
        self.dataWindow = dataWindow
        self.comparedTo = comparedTo
        self.deviation = deviation
    }
}

// MARK: - MetricSource + Citation

public struct MetricSource: Codable, Sendable, Hashable {
    /// Stable contract identifier (`"bloodPressure"`, `"weight"`,
    /// `"medications.compliance30"` …). Never localise — UI translates
    /// at render time via the ``localizedLabel`` helper.
    public let type: String
    public let timeRange: String
    public let summary: String
    public let n: Int?

    public init(type: String, timeRange: String, summary: String, n: Int? = nil) {
        self.type = type
        self.timeRange = timeRange
        self.summary = summary
        self.n = n
    }
}

public struct Citation: Codable, Sendable, Hashable, Identifiable {
    /// Citations have no server-side `id` — derive one from the
    /// `(type, timeRange)` pair. This matches the contract that every
    /// recommendation's `metricSource` MUST appear here exactly once
    /// (15-insights-architecture §"Citation-grounding").
    public var id: String {
        "\(type)-\(timeRange)"
    }

    public let type: String
    public let timeRange: String
    public let summary: String

    public init(type: String, timeRange: String, summary: String) {
        self.type = type
        self.timeRange = timeRange
        self.summary = summary
    }
}

// MARK: - Warnings

public struct InsightWarning: Codable, Sendable, Hashable, Identifiable {
    /// Warnings carry no server-side id — synth from `(topic, message)`
    /// so SwiftUI's ForEach has a stable identity.
    public var id: String {
        "\(topic)-\(message.hashValue)"
    }

    public let topic: String
    public let message: String
    public let severity: WarningSeverity?

    public init(topic: String, message: String, severity: WarningSeverity? = nil) {
        self.topic = topic
        self.message = message
        self.severity = severity
    }
}

public enum WarningSeverity: String, Codable, Sendable {
    case info
    case warning
    case important
}

// MARK: - DailyBriefing

public struct DailyBriefing: Codable, Sendable, Hashable {
    public let paragraph: String
    public let keyFindings: [KeyFinding]

    /// **v1.18.7 — "Signals of the day"** (server `signalsOfDay`). The
    /// present-focused lead of the rebuilt briefing: 0-3 NOW-anchored reads of
    /// what a metric is doing against the user's own recent baseline, each
    /// paired with one concrete, doable nudge. Render-only — the server hands
    /// the comparison already finished (delta + tone verdict); iOS never
    /// recomputes it. Optional so pre-v1.18.7 cached payloads round-trip.
    public let signalsOfDay: [DailyBriefingSignal]

    public init(
        paragraph: String,
        keyFindings: [KeyFinding] = [],
        signalsOfDay: [DailyBriefingSignal] = []
    ) {
        self.paragraph = paragraph
        self.keyFindings = keyFindings
        self.signalsOfDay = signalsOfDay
    }

    private enum CodingKeys: String, CodingKey {
        case paragraph
        case keyFindings
        case signalsOfDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paragraph = try container.decode(String.self, forKey: .paragraph)
        keyFindings = try container.decodeIfPresent([KeyFinding].self, forKey: .keyFindings) ?? []
        // Nullable + optional on the wire (server caps at 3) — tolerate
        // missing/null so legacy caches decode to an empty signals list.
        signalsOfDay = try container.decodeIfPresent([DailyBriefingSignal].self, forKey: .signalsOfDay) ?? []
    }
}

/// **v1.18.7** — one "Signal of the day". Mirrors the server
/// `dailyBriefingSignalSchema`: a present-tense headline + one concrete nudge,
/// toned `good` / `watch` / `info`, with an optional delta string
/// ("+6 mmHg vs your 30-day average"). Render-only — the prose and the delta
/// arrive finished from the server.
public struct DailyBriefingSignal: Codable, Sendable, Hashable, Identifiable {
    public var id: String {
        "\(sourceMetric)-\(headline)"
    }

    /// Metric the signal is drawn from — same discriminator as `KeyFinding`.
    public let sourceMetric: String
    /// Drives the accent colour, mirroring the key-finding tone ladder.
    public let tone: KeyFindingTone
    /// Present-tense headline — what is happening NOW (the user reads first).
    public let headline: String
    /// One concrete, doable nudge tied to the signal.
    public let nudge: String
    /// Optional delta string — e.g. "+6 mmHg vs your 30-day average".
    public let delta: String?

    public init(
        sourceMetric: String,
        tone: KeyFindingTone,
        headline: String,
        nudge: String,
        delta: String? = nil
    ) {
        self.sourceMetric = sourceMetric
        self.tone = tone
        self.headline = headline
        self.nudge = nudge
        self.delta = delta
    }
}

public struct KeyFinding: Codable, Sendable, Hashable, Identifiable {
    public var id: String {
        "\(sourceMetric)-\(sourceWindow)-\(headline)"
    }

    public let tone: KeyFindingTone
    public let headline: String
    public let detail: String
    public let delta: String?
    public let sourceWindow: String
    public let sourceMetric: String

    public init(
        tone: KeyFindingTone,
        headline: String,
        detail: String,
        delta: String? = nil,
        sourceWindow: String,
        sourceMetric: String
    ) {
        self.tone = tone
        self.headline = headline
        self.detail = detail
        self.delta = delta
        self.sourceWindow = sourceWindow
        self.sourceMetric = sourceMetric
    }
}

public enum KeyFindingTone: String, Codable, Sendable {
    case good
    case watch
    case info
}
