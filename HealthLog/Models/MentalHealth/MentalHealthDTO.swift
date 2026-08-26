import Foundation

// Wire DTOs for the v1.25 opt-in mental-health screener surface (PHQ-9 / GAD-7;
// server `W-MENTAL-HEALTH`).
//
// Source of truth (verified 2026-06-28 against the `HealthLog` server repo
// `release/v1.25.0`):
//   - `src/lib/openapi/routes/mental-health.ts` (wire DTOs)
//   - `src/lib/validations/mental-health.ts` (request schema)
//   - `src/app/api/mental-health/assessments/route.ts` (GET/POST handler)
//
// CONTRACT FACTS the client must honour:
//   - Per-item answers are encrypted at rest server-side and NEVER returned by
//     any endpoint. Only the derived `totalScore` / `severityBand` /
//     `item9Flagged` ride the wire. The raw item-9 value lives only in the
//     encrypted blob — the client holds it in-memory until the POST resolves and
//     never persists it.
//   - The POST response carries a `crisis: CrisisResourceSet | null`, present iff
//     `item9Flagged == true`. The set is SERVER-supplied literal data (emergency
//     number + resource ids + contact lines); every human-readable NAME / card
//     string is CLIENT-owned i18n (`Localizable.xcstrings`).
//   - No DELETE / PATCH route — history is append-only on the client.
//
// Responses are wrapped in the standard `{ data: … }` envelope, unwrapped by
// `APIClient.send`. Instant fields stay raw `String` (the wire is ISO-8601).

// MARK: - MentalHealthAssessmentDTO

/// One completed screener administration (`MentalHealthAssessment`). The raw
/// per-item answers are intentionally absent — `severityBand` is a descriptive
/// screen label, never a diagnosis; `item9Flagged` is the server-computed
/// self-harm flag (`items[8] > 0`).
public struct MentalHealthAssessmentDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let instrument: MentalHealthInstrument
    public let locale: String
    public let version: String
    public let totalScore: Int
    public let severityBand: String
    public let item9Flagged: Bool
    /// `YYYY-MM-DDTHH:mm:ssZ` or `nil` when the crisis card was never shown.
    public let crisisShownAt: String?
    public let takenAt: String
    public let createdAt: String

    public init(
        id: String,
        instrument: MentalHealthInstrument,
        locale: String,
        version: String,
        totalScore: Int,
        severityBand: String,
        item9Flagged: Bool,
        crisisShownAt: String?,
        takenAt: String,
        createdAt: String
    ) {
        self.id = id
        self.instrument = instrument
        self.locale = locale
        self.version = version
        self.totalScore = totalScore
        self.severityBand = severityBand
        self.item9Flagged = item9Flagged
        self.crisisShownAt = crisisShownAt
        self.takenAt = takenAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        // Parity 1.6a — deliberately NOT defaulted past an unknown value. An
        // instrument this client does not model (the server's SCI row) throws
        // out of `MentalHealthInstrument.init(from:)` and propagates here; the
        // history decoder drops the row rather than scoring it as PHQ-9. An
        // ABSENT key still defaults to `.phq9` (the historical single
        // instrument), which is a different and safe case.
        instrument = try c.decodeIfPresent(MentalHealthInstrument.self, forKey: .instrument) ?? .phq9
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "standard"
        totalScore = try c.decodeIfPresent(Int.self, forKey: .totalScore) ?? 0
        severityBand = try c.decodeIfPresent(String.self, forKey: .severityBand) ?? "minimal"
        item9Flagged = try c.decodeIfPresent(Bool.self, forKey: .item9Flagged) ?? false
        crisisShownAt = try c.decodeIfPresent(String.self, forKey: .crisisShownAt)
        takenAt = try c.decodeIfPresent(String.self, forKey: .takenAt) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

// MARK: - Crisis resources (server-supplied literal data)

/// One crisis resource: a stable `id` (its display NAME resolves CLIENT-side via
/// `mentalHealth.crisisResource.<id>.name`) + literal `contacts` (phone / SMS /
/// chat URL — never translated). Mirrors the server `CrisisResource`.
public struct CrisisResource: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let contacts: [String]

    public init(id: String, contacts: [String]) {
        self.id = id
        self.contacts = contacts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        contacts = try c.decodeIfPresent([String].self, forKey: .contacts) ?? []
    }
}

/// Locale-aware crisis-resource set (`CrisisResourceSet`). `emergencyNumber` is
/// the region's universal number, shown first. Present in the POST response only
/// when item-9 is flagged; the client also bundles a defensive fallback
/// (``CrisisResourceFallback``) for deploy-skew / offline.
public struct CrisisResourceSet: Codable, Sendable, Equatable {
    public let emergencyNumber: String
    public let resources: [CrisisResource]

    public init(emergencyNumber: String, resources: [CrisisResource]) {
        self.emergencyNumber = emergencyNumber
        self.resources = resources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emergencyNumber = try c.decodeIfPresent(String.self, forKey: .emergencyNumber) ?? ""
        resources = try c.decodeIfPresent([CrisisResource].self, forKey: .resources) ?? []
    }
}

// MARK: - Request / response

/// `POST /api/mental-health/assessments` body (`createAssessmentSchema`).
/// `userId` is NEVER a body field (narrowed server-side from the session).
/// `items` MUST be exactly `instrument.itemCount` long, each 0–3.
public struct CreateAssessmentRequest: Codable, Sendable, Equatable {
    public let instrument: MentalHealthInstrument
    public let items: [Int]
    /// Optional functional-impairment follow-up (0–3) — NOT scored into the total.
    public let functionalDifficulty: Int?
    /// The validated wording's locale actually presented ("de" / "en"), so the
    /// server resolves the matching crisis-resource set + records the locale.
    public let locale: String?
    /// #39 / server v1.25 — client provenance (`assessmentSourceEnum ∈
    /// {"WEB","IOS"}`; server defaults to `"WEB"`). iOS always sends `"IOS"` so
    /// its administrations are attributed correctly instead of mis-tagged WEB.
    public let source: String?
    /// #39 / server v1.25 — durable client idempotency id. A repeat submit with
    /// the same `externalId` returns the existing administration instead of
    /// minting a duplicate, closing the >24h outbox-replay double-submit gap the
    /// header idempotency-key alone (24h server window) leaves open. Kept in
    /// lockstep with the idempotency key (see ``MentalHealthRepository/submit``).
    public let externalId: String?

    public init(
        instrument: MentalHealthInstrument,
        items: [Int],
        functionalDifficulty: Int? = nil,
        locale: String? = nil,
        source: String? = nil,
        externalId: String? = nil
    ) {
        self.instrument = instrument
        self.items = items
        self.functionalDifficulty = functionalDifficulty
        self.locale = locale
        self.source = source
        self.externalId = externalId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instrument.rawValue, forKey: .instrument)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(functionalDifficulty, forKey: .functionalDifficulty)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(externalId, forKey: .externalId)
    }

    private enum CodingKeys: String, CodingKey {
        case instrument, items, functionalDifficulty, locale, source, externalId
    }
}

/// `POST` response (`CreateMentalHealthAssessmentResponse`). `crisis` is present
/// iff `assessment.item9Flagged == true`; the client tolerates `crisis: null`
/// and resolves its bundled fallback when the flag is set but the set is absent
/// (deploy skew).
public struct CreateAssessmentResponse: Codable, Sendable, Equatable {
    public let assessment: MentalHealthAssessmentDTO
    public let actionThreshold: Int
    public let crisis: CrisisResourceSet?

    public init(
        assessment: MentalHealthAssessmentDTO,
        actionThreshold: Int,
        crisis: CrisisResourceSet?
    ) {
        self.assessment = assessment
        self.actionThreshold = actionThreshold
        self.crisis = crisis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assessment = try c.decode(MentalHealthAssessmentDTO.self, forKey: .assessment)
        actionThreshold = try c.decodeIfPresent(Int.self, forKey: .actionThreshold) ?? 10
        crisis = try c.decodeIfPresent(CrisisResourceSet.self, forKey: .crisis)
    }
}

/// `GET /api/mental-health/assessments` response (`{ assessments: [...] }`,
/// newest-first). Raw item answers are never present.
public struct MentalHealthHistoryResponse: Codable, Sendable, Equatable {
    public let assessments: [MentalHealthAssessmentDTO]

    public init(assessments: [MentalHealthAssessmentDTO]) {
        self.assessments = assessments
    }

    /// **Parity 1.6a — element-wise lossy decode.**
    ///
    /// The history list is decoded row by row through a wrapper that never
    /// throws, so ONE unscoreable row (an instrument this client does not model
    /// — today the server's SCI) drops out instead of either (a) being scored
    /// against PHQ-9's bands, which is what the old defaulting decode did, or
    /// (b) failing the whole response and blanking the user's history.
    ///
    /// The wrapper is required rather than a `try?` inside a manual unkeyed
    /// loop: a failed `UnkeyedDecodingContainer.decode` leaves the cursor in an
    /// implementation-defined position, so the loop-and-skip idiom can silently
    /// eat the FOLLOWING row too. Decoding each element into an always-succeeding
    /// box keeps the cursor honest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try c.decodeIfPresent([LossyAssessmentRow].self, forKey: .assessments) ?? []
        assessments = rows.compactMap(\.value)
    }

    /// Decodes one history row, yielding `nil` instead of throwing.
    private struct LossyAssessmentRow: Decodable {
        let value: MentalHealthAssessmentDTO?

        init(from decoder: Decoder) throws {
            value = try? MentalHealthAssessmentDTO(from: decoder)
        }
    }
}
