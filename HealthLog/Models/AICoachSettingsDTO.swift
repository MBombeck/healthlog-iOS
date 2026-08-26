import Foundation

// **Build 6 / Item 6.6 — Coach/AI privacy settings wire shapes.**
//
// Two server-owned per-user AI flags that had **zero** iOS bindings before this
// item (handover-verified). Both are decoded tolerantly — a missing field
// resolves to the server's own default rather than throwing — so an older
// server (or a partial payload) never crashes the Coach settings surface.
//
// ## `documentsAutoAiRead`
// `GET / PATCH /api/auth/me/documents-auto-ai-read`
// (server `src/app/api/auth/me/documents-auto-ai-read/route.ts`). A single
// boolean, **OFF by default**. When ON, a freshly uploaded document may be read
// by the configured external AI with no per-document tap — the operator's
// "documents-AI is auto-only" decision: this flag IS the switch, there is no
// explicit "read with AI" button. Flipping it ON is itself the standing consent
// act (the server mints an `ai_full` consent receipt server-side).
//
// ## `insightsPrivacyMode`
// `GET / PUT /api/insights/settings`
// (server `src/app/api/insights/settings/route.ts`). Exposed on the wire as
// `privacyMode`. Server enum — exactly `"aggregated"` (default) or `"raw"`;
// `"raw"` sets `includeRaw = true` in the comprehensive-insights prompt
// builder, i.e. it controls how much data detail the Insights AI is handed, not
// whether AI runs at all.

// MARK: - documentsAutoAiRead

/// Wire shape for `GET / PATCH /api/auth/me/documents-auto-ai-read`. The server
/// always echoes the resolved next state as `{ documentsAutoAiRead: Bool }`.
public struct DocumentsAutoAiReadDTO: Codable, Sendable, Hashable {
    public let documentsAutoAiRead: Bool

    public init(documentsAutoAiRead: Bool) {
        self.documentsAutoAiRead = documentsAutoAiRead
    }

    /// Tolerant decode: a payload that omits the field resolves to the server's
    /// OFF-by-default contract rather than throwing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentsAutoAiRead = try container.decodeIfPresent(Bool.self, forKey: .documentsAutoAiRead) ?? false
    }
}

/// PATCH body — the single boolean the server's zod schema requires.
public struct DocumentsAutoAiReadWrite: Codable, Sendable {
    public let documentsAutoAiRead: Bool

    public init(documentsAutoAiRead: Bool) {
        self.documentsAutoAiRead = documentsAutoAiRead
    }
}

// MARK: - disableCoach (Build 9 / 9.2)

/// Wire shape for `GET / PATCH /api/auth/me/disable-coach`. The server always
/// echoes the resolved next state as `{ disableCoach: Bool }` (`?? false`).
/// Tolerant decode: a payload that omits the field resolves to `false` (coach
/// available) rather than throwing.
public struct DisableCoachDTO: Codable, Sendable, Hashable {
    public let disableCoach: Bool

    public init(disableCoach: Bool) {
        self.disableCoach = disableCoach
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disableCoach = try container.decodeIfPresent(Bool.self, forKey: .disableCoach) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case disableCoach
    }
}

/// PATCH body — the single boolean the server's zod schema requires.
public struct DisableCoachWrite: Codable, Sendable {
    public let disableCoach: Bool

    public init(disableCoach: Bool) {
        self.disableCoach = disableCoach
    }
}

// MARK: - insightsPrivacyMode

/// The two server-accepted insights privacy modes. Raw values are the exact
/// on-wire tokens the `PUT /api/insights/settings` zod guard validates
/// (`["aggregated", "raw"]`); do not add cases without a server change.
public enum InsightsPrivacyMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Default. Only aggregated / summarised data is handed to the Insights AI.
    case aggregated
    /// The Insights AI additionally receives raw data points (`includeRaw`).
    case raw

    public var id: String {
        rawValue
    }

    /// Catalog key for the option's display label (resolved to de/en in the
    /// Coach settings picker). Never hardcode the German here.
    public var labelKey: String {
        switch self {
        case .aggregated: "settings.coach.insightsPrivacy.aggregated"
        case .raw: "settings.coach.insightsPrivacy.raw"
        }
    }
}

/// Wire shape for `GET /api/insights/settings`. The endpoint returns a wide
/// payload (connection status, admin-key presence, …); we decode only the field this
/// surface owns. Extra keys are ignored by `Decodable`, and a missing / unknown
/// `privacyMode` resolves to the server default (`aggregated`).
public struct InsightsPrivacySettingsDTO: Codable, Sendable, Hashable {
    public let privacyMode: InsightsPrivacyMode

    public init(privacyMode: InsightsPrivacyMode) {
        self.privacyMode = privacyMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode the raw token defensively: a missing key OR a token this build
        // does not know (a future server mode) both fall back to the safe
        // `aggregated` default rather than throwing.
        let raw = try container.decodeIfPresent(String.self, forKey: .privacyMode)
        privacyMode = raw.flatMap(InsightsPrivacyMode.init(rawValue:)) ?? .aggregated
    }

    private enum CodingKeys: String, CodingKey {
        case privacyMode
    }
}

/// PUT body for `/api/insights/settings`. Server accepts `{ privacyMode }`;
/// switching the mode also clears the server-cached insight text server-side.
public struct InsightsPrivacyModeWrite: Codable, Sendable {
    public let privacyMode: String

    public init(privacyMode: InsightsPrivacyMode) {
        self.privacyMode = privacyMode.rawValue
    }
}
