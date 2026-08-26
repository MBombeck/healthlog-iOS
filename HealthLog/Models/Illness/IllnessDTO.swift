import Foundation

// Wire DTOs for the v1.18.1 illness / condition-journal surface (server `W-B`).
//
// Source of truth (verified 2026-06-17 against the `HealthLog` server repo):
//   - `docs/api/openapi.yaml` → `IllnessEpisode` / `IllnessDayLog` /
//     `IllnessSymptom` / `IllnessCorrelationResponse` (+ `IllnessCorrelationValue`,
//     `IllnessVitalDeviation`, `IllnessVitalReturn`, `IllnessRedFlag`) /
//     `IllnessInsightsResponse`, plus the list / single / day-log envelopes.
//   - `.planning/ios-coord/v1.18.1-server-to-ios-contract.md` §2.
//   - `.planning/v0149-coherence/SPEC-labs-illness.md` §B.
//
// CONTRACT FACTS the client must honour:
//   - **Default-ON module (v1.18.3).** The born-gating was dropped: illness is a
//     normal default-ON toggle. Every `/api/illness/*` route still 403s with
//     `meta.errorCode: "illness.disabled"` + `meta.module: "illness"` when a user
//     has *disabled* the module (or the operator disabled it server-wide). The
//     surface gates on `ModuleGate.isEnabled(.illness)` (default-ON). See
//     ``IllnessRepository``.
//   - **Correlation + insights are SERVER-COMPUTED, render-only.** The
//     `IllnessCorrelationResponse` carries a coverage-gated `Derived<T>`: signed
//     deviations in robust-SD units from the user's OWN baseline (median ± MAD),
//     per-vital returns, the headline recovery-gap, and any red flags. iOS
//     pattern-matches `status` (`ok | insufficient`) and renders `value` or a
//     "still learning" state — it computes NO baseline.
//   - **Retrospective ONLY.** Correlation + insights describe the past; the
//     surface must NEVER predict, diagnose, or forecast. Red-flag copy escalates
//     ("seek care if this recurs"), never reassures.
//   - **note null-on-key-rotation is fail-soft.** A null `note` is not an error.
//
// Every struct is `Sendable` + `Codable` with **tolerant decode**
// (`decodeIfPresent` + safe defaults) so a field added later — or an unknown
// enum member — never hard-fails the whole envelope (CycleDTO / LabsDTO
// precedent). Calendar / instant date fields stay raw `String` (the wire is
// ISO-8601 / `YYYY-MM-DD`).

// MARK: - IllnessType

/// `{ INFECTION | ALLERGY | INJURY | MENTAL_HEALTH | AUTOIMMUNE | CHRONIC |
/// OTHER }` — the episode classification. Tolerant decode: an unknown wire
/// string falls back to ``other`` rather than failing the whole episode decode.
public enum IllnessType: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case infection = "INFECTION"
    case allergy = "ALLERGY"
    case injury = "INJURY"
    case mentalHealth = "MENTAL_HEALTH"
    case autoimmune = "AUTOIMMUNE"
    case chronic = "CHRONIC"
    case other = "OTHER"

    public var id: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IllnessType(rawValue: raw) ?? .other
    }
}

// MARK: - IllnessLifecycle

/// `{ ACUTE | CHRONIC_ONGOING | RECURRING | FLARE }` — the episode lifecycle.
/// `CHRONIC_ONGOING` has no recovery date (the resolve route 422s for it).
/// Tolerant decode falls back to ``acute``.
public enum IllnessLifecycle: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    case acute = "ACUTE"
    case chronicOngoing = "CHRONIC_ONGOING"
    case recurring = "RECURRING"
    case flare = "FLARE"

    public var id: String {
        rawValue
    }

    /// A `CHRONIC_ONGOING` episode can never be resolved (the server 422s with
    /// `illness.episode.chronic-no-resolve`) — the UI hides the resolve action.
    public var isResolvable: Bool {
        self != .chronicOngoing
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IllnessLifecycle(rawValue: raw) ?? .acute
    }
}

// MARK: - IllnessEpisodeDTO

/// One stored illness/condition episode (`IllnessEpisode`). `note` is the
/// decrypted free-text (or `nil` on a key-rotation gap — fail-soft, never an
/// error). `resolvedAt` is `nil` while the episode is open. `parentConditionId`
/// links a FLARE/RECURRING bout to its parent condition.
public struct IllnessEpisodeDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let label: String
    public let type: IllnessType
    public let lifecycle: IllnessLifecycle
    /// `YYYY-MM-DDTHH:mm:ssZ`.
    public let onsetAt: String
    /// `nil` while the episode is still open (unresolved).
    public let resolvedAt: String?
    public let parentConditionId: String?
    /// Decrypted free-text note (server-side decryption) or `nil`.
    public let note: String?
    public let createdAt: String
    public let updatedAt: String

    /// True while the episode is open (unresolved) — drives the rest-mode
    /// `hasActiveEpisode` annotation and the journal's active/resolved filter.
    public var isActive: Bool {
        (resolvedAt ?? "").isEmpty
    }

    public init(
        id: String,
        label: String,
        type: IllnessType,
        lifecycle: IllnessLifecycle,
        onsetAt: String,
        resolvedAt: String?,
        parentConditionId: String?,
        note: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.lifecycle = lifecycle
        self.onsetAt = onsetAt
        self.resolvedAt = resolvedAt
        self.parentConditionId = parentConditionId
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        type = try c.decodeIfPresent(IllnessType.self, forKey: .type) ?? .other
        lifecycle = try c.decodeIfPresent(IllnessLifecycle.self, forKey: .lifecycle) ?? .acute
        onsetAt = try c.decodeIfPresent(String.self, forKey: .onsetAt) ?? ""
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt)
        parentConditionId = try c.decodeIfPresent(String.self, forKey: .parentConditionId)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - IllnessSymptom

/// A symptom link on a day-log: the catalog `key` plus an optional 1–3 graded
/// severity (`nil` = a plain presence link; the link's presence already means
/// "present", so 0 is not a distinct state).
public struct IllnessSymptom: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let key: String
    public let severity: Int?

    public var id: String {
        key
    }

    private enum CodingKeys: String, CodingKey {
        case key, severity
    }

    /// The valid graded-severity range (v1.18.3): `1...3`. `nil` is a plain
    /// presence link (no grade); `0` is NOT a distinct state (the link's
    /// presence already means "present"). Out-of-range / `0` values are clamped
    /// into the range on decode so a stray wire value never paints a bogus grade.
    public static let severityRange: ClosedRange<Int> = 1 ... 3

    public init(key: String, severity: Int? = nil) {
        self.key = key
        self.severity = Self.clampSeverity(severity)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        severity = try Self.clampSeverity(c.decodeIfPresent(Int.self, forKey: .severity))
    }

    /// Clamp a raw severity into the 1–3 range; `nil` (and a stray `0`) stay a
    /// plain presence link.
    private static func clampSeverity(_ raw: Int?) -> Int? {
        guard let raw else { return nil }
        if raw <= 0 { return nil }
        return min(max(raw, severityRange.lowerBound), severityRange.upperBound)
    }

    /// Only emit `severity` when set so a plain presence link stays a plain
    /// link on the wire (`null` severity is valid).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encodeIfPresent(severity, forKey: .severity)
    }
}

// MARK: - IllnessDayLogDTO

/// A stored day-log for an episode (`IllnessDayLog`). `date` is the
/// `YYYY-MM-DD` it covers. `functionalImpact` (0–3) and `feverC` are plaintext;
/// `symptoms` flattens the link rows; `note` is the decrypted free-text (or nil).
public struct IllnessDayLogDTO: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let episodeId: String
    /// `YYYY-MM-DD`.
    public let date: String
    public let functionalImpact: Int?
    public let feverC: Double?
    public let symptoms: [IllnessSymptom]
    public let note: String?
    public let updatedAt: String

    public init(
        id: String,
        episodeId: String,
        date: String,
        functionalImpact: Int?,
        feverC: Double?,
        symptoms: [IllnessSymptom],
        note: String?,
        updatedAt: String
    ) {
        self.id = id
        self.episodeId = episodeId
        self.date = date
        self.functionalImpact = functionalImpact
        self.feverC = feverC
        self.symptoms = symptoms
        self.note = note
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        functionalImpact = try c.decodeIfPresent(Int.self, forKey: .functionalImpact)
        feverC = try c.decodeIfPresent(Double.self, forKey: .feverC)
        symptoms = try c.decodeIfPresent([IllnessSymptom].self, forKey: .symptoms) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

// MARK: - GetIllnessDayLog wrapper (the route returns the DTO OR null)

/// `GET /api/illness/episodes/{id}/day-logs?date=` returns the day-log for that
/// date **or `null`** (lets the log-day sheet pre-fill).
///
/// `APIClient.send` strips the outer `{ data, error }` envelope and returns the
/// `data` position — BUT `APIEnvelope.decodeIfPresent` cannot tell present-`null`
/// from absent, so a `data: null` response falls through to decoding the FULL
/// envelope object. This wrapper therefore handles BOTH shapes:
/// - the DTO object directly (`data` was present → `send` returns it), and
/// - the full envelope object (`data` was null → fallback path) — in which case
///   we read the (null) `data` key and yield `nil`.
/// The repo reads ``dayLog``.
public struct IllnessDayLogNullable: Decodable, Sendable, Equatable {
    public let dayLog: IllnessDayLogDTO?

    public init(dayLog: IllnessDayLogDTO?) {
        self.dayLog = dayLog
    }

    private enum EnvelopeKeys: String, CodingKey {
        case data
    }

    public init(from decoder: Decoder) throws {
        // Case 1: the envelope object reached us (data was null on the wire).
        if let env = try? decoder.container(keyedBy: EnvelopeKeys.self),
           env.contains(.data)
        {
            dayLog = try env.decodeIfPresent(IllnessDayLogDTO.self, forKey: .data)
            return
        }
        // Case 2: the DTO object reached us directly (data was present).
        dayLog = try? IllnessDayLogDTO(from: decoder)
    }
}

// MARK: - IllnessDayLogList (the date-less LIST mode, v1.18.3)

/// `GET /api/illness/episodes/{id}/day-logs` with NO `date` returns the episode's
/// full day-log history (`IllnessDayLogList`): `dayLogs` newest-first (or
/// oldest-first under `sortDir:'asc'`), with `meta.total` / `limit` / `offset`
/// for paging. `APIClient.send` strips the outer `{ data, error }` envelope, so
/// the repo decodes this `data`-position object directly.
public struct IllnessDayLogList: Decodable, Sendable, Equatable {
    public let dayLogs: [IllnessDayLogDTO]
    public let meta: Meta

    public struct Meta: Decodable, Sendable, Equatable {
        public let total: Int
        public let limit: Int
        public let offset: Int

        public init(total: Int, limit: Int, offset: Int) {
            self.total = total
            self.limit = limit
            self.offset = offset
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 0
            offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        }

        private enum CodingKeys: String, CodingKey {
            case total, limit, offset
        }
    }

    public init(dayLogs: [IllnessDayLogDTO], meta: Meta) {
        self.dayLogs = dayLogs
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayLogs = try c.decodeIfPresent([IllnessDayLogDTO].self, forKey: .dayLogs) ?? []
        meta = try c.decodeIfPresent(Meta.self, forKey: .meta) ?? Meta(total: 0, limit: 0, offset: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case dayLogs, meta
    }
}

// MARK: - DeleteIllnessEpisodeResult (DELETE response, v1.18.3)

/// `DELETE /api/illness/episodes/{id}` returns `200 { data: { deleted: true },
/// error: null }` (changed from a bare `204` in v1.18.3; idempotent — a
/// re-delete is a no-op). `APIClient.send` strips the envelope and decodes this
/// `data`-position object. Tolerant: a missing `deleted` defaults `false`, and a
/// bare `{}` / empty body still decodes (so a transitional `204` server never
/// breaks the call).
public struct DeleteIllnessEpisodeResult: Decodable, Sendable, Equatable {
    public let deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        deleted = (try? c?.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case deleted
    }
}

// MARK: - Write bodies

/// `POST /api/illness/episodes`. `label` + `type` required; `lifecycle` defaults
/// `ACUTE` server-side. Only emits set keys so an omitted field is "untouched".
public struct IllnessEpisodeCreate: Codable, Sendable, Equatable {
    public var label: String
    public var type: IllnessType
    public var lifecycle: IllnessLifecycle?
    public var onsetAt: String?
    public var resolvedAt: String?
    public var parentConditionId: String?
    public var note: String?

    public init(
        label: String,
        type: IllnessType,
        lifecycle: IllnessLifecycle? = nil,
        onsetAt: String? = nil,
        resolvedAt: String? = nil,
        parentConditionId: String? = nil,
        note: String? = nil
    ) {
        self.label = label
        self.type = type
        self.lifecycle = lifecycle
        self.onsetAt = onsetAt
        self.resolvedAt = resolvedAt
        self.parentConditionId = parentConditionId
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(type.rawValue, forKey: .type)
        try c.encodeIfPresent(lifecycle?.rawValue, forKey: .lifecycle)
        try c.encodeIfPresent(onsetAt, forKey: .onsetAt)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try c.encodeIfPresent(parentConditionId, forKey: .parentConditionId)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// `PATCH /api/illness/episodes/{id}` partial edit. Scalar fields remain
/// optional: an omitted key is untouched.
///
/// `resolvedAt`, `parentConditionId`, and `note` are full-value fields. The
/// server distinguishes an omitted key from a present JSON `null`: `null`
/// reopens an episode, unlinks its parent, or clears its note. They are therefore
/// always emitted, while callers may still leave scalar fields untouched.
public struct IllnessEpisodePatch: Codable, Sendable, Equatable {
    public var label: String?
    public var type: IllnessType?
    public var lifecycle: IllnessLifecycle?
    public var onsetAt: String?
    public var resolvedAt: String?
    public var parentConditionId: String?
    public var note: String?

    public init(
        label: String? = nil,
        type: IllnessType? = nil,
        lifecycle: IllnessLifecycle? = nil,
        onsetAt: String? = nil,
        resolvedAt: String? = nil,
        parentConditionId: String? = nil,
        note: String? = nil
    ) {
        self.label = label
        self.type = type
        self.lifecycle = lifecycle
        self.onsetAt = onsetAt
        self.resolvedAt = resolvedAt
        self.parentConditionId = parentConditionId
        self.note = note
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(type?.rawValue, forKey: .type)
        try c.encodeIfPresent(lifecycle?.rawValue, forKey: .lifecycle)
        try c.encodeIfPresent(onsetAt, forKey: .onsetAt)
        try c.encode(resolvedAt, forKey: .resolvedAt)
        try c.encode(parentConditionId, forKey: .parentConditionId)
        try c.encode(note, forKey: .note)
    }
}

/// `PATCH /api/illness/episodes/{id}/resolve`. `resolvedAt` is optional — when
/// omitted the server stamps 'now'. A `CHRONIC_ONGOING` episode 422s with
/// `illness.episode.chronic-no-resolve`.
public struct IllnessResolveBody: Codable, Sendable, Equatable {
    public var resolvedAt: String?

    public init(resolvedAt: String? = nil) {
        self.resolvedAt = resolvedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
    }
}

/// `POST /api/illness/episodes/{id}/day-logs` upsert body. `date` required; the
/// rest optional. Upserts on `(episodeId, date)`: 201 insert / 200 update.
///
/// **Full-value body, not a partial patch (parity 1.7).** The server merges
/// `functionalImpact` / `feverC` / `note` as "key omitted ⇒ keep the stored
/// value, key present ⇒ replace (explicit `null` clears)"
/// (`src/lib/illness/day-log-write.ts:118-143`). `encodeIfPresent` therefore
/// made *clearing* any of the three impossible — a deleted note, a switched-off
/// fever, and a de-selected impact all silently came back on the next read.
/// All three are now ALWAYS emitted, `nil` as an explicit JSON `null`, exactly
/// as the web `log-day-sheet.tsx:213-221` sends them. `symptoms` was already
/// unconditional. Callers must build this from the FULL day-log form.
public struct IllnessDayLogUpsert: Codable, Sendable, Equatable {
    /// `YYYY-MM-DD`.
    public var date: String
    public var functionalImpact: Int?
    public var feverC: Double?
    public var symptoms: [IllnessSymptom]
    public var note: String?
    public var loggedAt: String?

    public init(
        date: String,
        functionalImpact: Int? = nil,
        feverC: Double? = nil,
        symptoms: [IllnessSymptom] = [],
        note: String? = nil,
        loggedAt: String? = nil
    ) {
        self.date = date
        self.functionalImpact = functionalImpact
        self.feverC = feverC
        self.symptoms = symptoms
        self.note = note
        self.loggedAt = loggedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        // Parity 1.7 — the three clearable fields are ALWAYS emitted, `nil` as
        // an explicit `null`; an omitted key means "keep stored" server-side.
        try c.encode(functionalImpact, forKey: .functionalImpact)
        try c.encode(feverC, forKey: .feverC)
        // Always emit symptoms (an empty array is a valid "no symptoms today").
        try c.encode(symptoms, forKey: .symptoms)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(loggedAt, forKey: .loggedAt)
    }
}

// MARK: - Symptom catalog (mirrors server `symptom-catalog.ts`, seed 0171)

/// The fixed symptom catalog seeded server-side (`ILLNESS_SYMPTOM_CATALOG`,
/// migration 0171). `key` is the snake_case DB key sent in `symptoms[].key`;
/// `labelKey` + `icon` drive the log-day picker. Kept in lockstep with the
/// server seed — new keys land here when the server adds them.
public struct IllnessSymptomCatalogEntry: Sendable, Equatable, Identifiable, Hashable {
    public let key: String
    public let labelKey: String
    public let icon: String

    public var id: String {
        key
    }

    public init(key: String, labelKey: String, icon: String) {
        self.key = key
        self.labelKey = labelKey
        self.icon = icon
    }
}

public enum IllnessSymptomCatalog {
    /// The seeded catalog (8 entries; server migration 0171). SF Symbols stand
    /// in for the web Lucide icons.
    public static let all: [IllnessSymptomCatalogEntry] = [
        .init(key: "runny_nose", labelKey: "illness.symptom.runnyNose", icon: "drop"),
        .init(key: "stuffy_nose", labelKey: "illness.symptom.stuffyNose", icon: "wind"),
        .init(key: "sneezing", labelKey: "illness.symptom.sneezing", icon: "humidity"),
        .init(key: "sore_throat", labelKey: "illness.symptom.soreThroat", icon: "flame"),
        .init(key: "cough", labelKey: "illness.symptom.cough", icon: "megaphone"),
        .init(key: "headache", labelKey: "illness.symptom.headache", icon: "brain.head.profile"),
        .init(key: "body_aches", labelKey: "illness.symptom.bodyAches", icon: "figure.walk"),
        .init(key: "fatigue", labelKey: "illness.symptom.fatigue", icon: "battery.25")
    ]

    /// Resolve a wire `key` to its catalog entry (or `nil` for an unknown
    /// future key — the UI then renders the raw key, never crashes).
    public static func entry(for key: String) -> IllnessSymptomCatalogEntry? {
        all.first { $0.key == key }
    }
}
