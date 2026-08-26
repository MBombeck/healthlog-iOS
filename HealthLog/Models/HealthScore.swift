import Foundation

/// **Health Score v2 (server v1.34.0) — the composite as `GET /api/dashboard/snapshot`
/// emits it under `healthScore`.**
///
/// The server rebuilt the score in v1.34.0 (`feat(analytics): replace health
/// score with reference composite`). The old four-pillar shape
/// (`components: { bp, weight, mood, compliance }` off `/api/analytics`) no
/// longer exists on any wire: `/api/analytics` now carries the internal
/// `HealthScoreReport` (a `composite` / `pillars` / `weightGoal` report with no
/// top-level `score`), while the **snapshot** carries the flat, client-shaped
/// DTO this type mirrors.
///
/// Only ``score``, ``band`` and ``delta`` are contractual. Everything else is
/// decoded **strictly optional** — the server marks eight of the eleven keys
/// optional so older *cached* snapshot cells stay valid, and iOS must never
/// fail a whole snapshot over a field it did not get.
///
/// **Never recomputed.** Every number here is server-resolved; iOS renders.
public struct HealthScore: Codable, Sendable, Hashable {
    /// Composite score 0…100, `Math.round(mean(eligible pillars))`.
    public let score: Int
    /// Server-derived band — green / yellow / red. Tolerant: an unknown future
    /// band token decodes as `nil` rather than throwing the score away.
    public let band: HealthScoreBand?
    /// Week-over-week change, server-rounded. `nil` whenever ``deltaReason`` is
    /// set — the two are mutually exclusive on the wire.
    public let delta: Int?
    /// Coverage-derived confidence in the number (`{ score, band }`).
    public let confidence: HealthScoreConfidence?
    /// The pillars that actually backed this score, in the server's registry
    /// order. Three to eight entries, no duplicates. This is the *identity* of
    /// the number, not a breakdown — the per-pillar values deliberately do not
    /// ride this wire.
    public let composition: [HealthScorePillar]?
    /// **v1.35.0 — "this score runs on a composition the person chose."**
    ///
    /// Server-resolved and mirrored verbatim: `true` when the account's resolved
    /// composition differs from the one its own defaults would resolve to
    /// *today*. An account whose set is narrower only because modules are
    /// switched off is deliberately **not** configured — the modules say what is
    /// recorded, not what should count. iOS never derives this from
    /// ``composition``; the two answer different questions.
    ///
    /// Strictly optional like its siblings: an older cached snapshot cell has no
    /// such key, and "we were not told" must not be painted as "not configured".
    public let configured: Bool?
    /// Why there is no ``delta``. `nil` means "a real delta is present".
    public let deltaReason: HealthScoreDeltaReason?
    /// Algorithm generation behind ``score`` (`SCORE_VERSION`, today `2`).
    public let scoreVersion: Int?
    /// The pillar that pulled the band below the mean's own band — an
    /// explanation of *which* signal set the colour, never a verdict. `nil`
    /// when the mean's band stands on its own.
    public let bandSetter: HealthScorePillar?
    /// Rest-mode annotation — frames the score ("you were resting in this
    /// window"), never changes it. `nil` when no episode is active; the server
    /// omits the annotation entirely rather than sending `active: false`.
    public let restMode: RestModeAnnotation?

    public init(
        score: Int,
        band: HealthScoreBand?,
        delta: Int?,
        confidence: HealthScoreConfidence? = nil,
        composition: [HealthScorePillar]? = nil,
        configured: Bool? = nil,
        deltaReason: HealthScoreDeltaReason? = nil,
        scoreVersion: Int? = nil,
        bandSetter: HealthScorePillar? = nil,
        restMode: RestModeAnnotation? = nil
    ) {
        self.score = score
        self.band = band
        self.delta = delta
        self.confidence = confidence
        self.composition = composition
        self.configured = configured
        self.deltaReason = deltaReason
        self.scoreVersion = scoreVersion
        self.bandSetter = bandSetter
        self.restMode = restMode
    }

    private enum CodingKeys: String, CodingKey {
        case score, band, delta, confidence, composition, configured
        case deltaReason, scoreVersion, bandSetter, restMode
    }

    /// Strictly optional past the three contractual fields. A malformed
    /// sub-object degrades to `nil` instead of failing the snapshot read: the
    /// live builder sends all eleven keys, but a stale cached cell may carry
    /// fewer, and the OpenAPI schema is known to lag the source (`tension` /
    /// `returnToBand` / `briefingMemory` are undocumented but shipped).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        // Tolerant band: an unknown token must not cost us the whole score.
        band = try? c.decodeIfPresent(HealthScoreBand.self, forKey: .band)
        delta = try c.decodeIfPresent(Int.self, forKey: .delta)
        confidence = try? c.decodeIfPresent(HealthScoreConfidence.self, forKey: .confidence)
        composition = try? c.decodeIfPresent([HealthScorePillar].self, forKey: .composition)
        configured = try? c.decodeIfPresent(Bool.self, forKey: .configured)
        deltaReason = try? c.decodeIfPresent(HealthScoreDeltaReason.self, forKey: .deltaReason)
        scoreVersion = try? c.decodeIfPresent(Int.self, forKey: .scoreVersion)
        bandSetter = try? c.decodeIfPresent(HealthScorePillar.self, forKey: .bandSetter)
        restMode = try? c.decodeIfPresent(RestModeAnnotation.self, forKey: .restMode)
    }

    /// **v0.14.10 §2 — iOS-side COLOUR band thresholds.**
    ///
    /// Fallback only: the colour banding the UI shows for a score when the
    /// server emits no `band` token (older servers). Does NOT recompute the
    /// score itself.
    ///
    /// - **green** for 67…100, **yellow** for 34…66, **red** for 0…33.
    public static func colorBand(forScore score: Int) -> HealthScoreBand {
        switch score {
        case 67...: .green
        case 34...: .yellow
        default: .red
        }
    }

    /// The colour band for THIS score's numeric value (see ``colorBand(forScore:)``).
    public var colorBand: HealthScoreBand {
        Self.colorBand(forScore: score)
    }

    /// **W-B187 / #27 — the band that drives the UI colour + label.**
    ///
    /// Prefers the server-authoritative ``band`` token so the Dashboard tile
    /// and the Insights score surfaces agree ("one engine"). Falls back to the
    /// local numeric thresholds ONLY when the server emits no band.
    public var displayBand: HealthScoreBand {
        band ?? colorBand
    }
}

// MARK: - Delta narration

public extension HealthScore {
    /// **The narration gate.** `true` when the surface must NOT tell a
    /// week-over-week story for this score.
    ///
    /// A non-null ``deltaReason`` always comes with `delta: null`, so there is
    /// nothing to narrate anyway — but the point is stronger than "hide the
    /// chip": three of the six reasons say **the measurement changed, not the
    /// person** (see ``HealthScoreDeltaReason/isMeasurementArtefact``). A jump
    /// after the server changed how it counts is not news about the user, and
    /// the surface has to keep the two apart.
    var suppressesDeltaNarrative: Bool {
        deltaReason != nil
    }

    /// The delta to narrate as a change in the person, or `nil` when there is
    /// none to tell. Callers render ``deltaReason`` prose instead.
    var narratableDelta: Int? {
        suppressesDeltaNarrative ? nil : delta
    }

    /// The resolved Rest Mode annotation IFF the server flagged it active —
    /// otherwise `nil`. Mirrors the server flag; never a local recompute.
    var activeRestMode: RestModeAnnotation? {
        guard let restMode, restMode.active else { return nil }
        return restMode
    }

    /// **The provenance gate for every surface that shows this number alone.**
    ///
    /// `true` only when the server said so. A missing key (older server, older
    /// cached cell) means we were not told, and a surface that painted an
    /// untold flag as a claim would be inventing provenance — so absence reads
    /// as "say nothing", never as "configured".
    var runsOnChosenComposition: Bool {
        configured == true
    }
}

// MARK: - Band

public enum HealthScoreBand: String, Codable, Sendable {
    case green
    case yellow
    case red
}

public extension HealthScoreBand {
    /// Case-insensitive decode. An unknown token throws so the tolerant
    /// `try?` at the ``HealthScore`` call site maps it to `nil`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        guard let value = HealthScoreBand(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown HealthScoreBand: \(raw)"
            )
        }
        self = value
    }
}

// MARK: - Confidence

/// Coverage-derived confidence in the composite (`deriveCoverage`). Both
/// sub-fields are non-null when the object is present.
public struct HealthScoreConfidence: Codable, Sendable, Hashable {
    /// 0…100 coverage score.
    public let score: Int
    /// Qualitative band — high / medium / low / draft (tolerant).
    public let band: HealthScoreConfidenceBand

    public init(score: Int, band: HealthScoreConfidenceBand) {
        self.score = score
        self.band = band
    }

    private enum CodingKeys: String, CodingKey {
        case score, band
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        band = try c.decodeIfPresent(HealthScoreConfidenceBand.self, forKey: .band)
            ?? .unknown("")
    }
}

/// `"high" | "medium" | "low" | "draft"` with a forward-compatible arm.
public enum HealthScoreConfidenceBand: Codable, Sendable, Hashable {
    case high
    case medium
    case low
    case draft
    /// Any token this client does not know yet — rendered as "unknown", never
    /// dressed up as one of the known bands.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        case "draft": self = .draft
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        case .draft: "draft"
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

// MARK: - Pillars

/// **The eight score pillars (server `SCORE_PILLAR_IDS`).**
///
/// Used for both ``HealthScore/composition`` and ``HealthScore/bandSetter``.
/// Tolerant with an ``unknown(_:)`` arm: the server may grow a ninth pillar,
/// and a single unfamiliar token must not throw away the composition — nor be
/// silently mislabelled as one of the eight we know.
public enum HealthScorePillar: Codable, Sendable, Hashable {
    case bloodPressure
    case glycaemia
    case activity
    case sleep
    case adiposity
    case wellbeing
    case fitness
    case lipids
    /// A pillar id this client does not know yet.
    case unknown(String)

    /// The eight known ids in the server's registry order — the order
    /// ``HealthScore/composition`` always arrives in.
    public static let known: [HealthScorePillar] = [
        .bloodPressure, .glycaemia, .activity, .sleep,
        .adiposity, .wellbeing, .fitness, .lipids
    ]

    public init(rawValue: String) {
        switch rawValue {
        case "BLOOD_PRESSURE": self = .bloodPressure
        case "GLYCAEMIA": self = .glycaemia
        case "ACTIVITY": self = .activity
        case "SLEEP": self = .sleep
        case "ADIPOSITY": self = .adiposity
        case "WELLBEING": self = .wellbeing
        case "FITNESS": self = .fitness
        case "LIPIDS": self = .lipids
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .bloodPressure: "BLOOD_PRESSURE"
        case .glycaemia: "GLYCAEMIA"
        case .activity: "ACTIVITY"
        case .sleep: "SLEEP"
        case .adiposity: "ADIPOSITY"
        case .wellbeing: "WELLBEING"
        case .fitness: "FITNESS"
        case .lipids: "LIPIDS"
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

// MARK: - Delta reason

/// **Why the server withheld the week-over-week delta (`ScoreDeltaReason`).**
///
/// Three of these are *measurement artefacts*: the number moved because the
/// way of measuring moved, or because there is not yet enough of a history to
/// compare against. Presenting those as "you changed" would be a lie about the
/// person, so ``isMeasurementArtefact`` marks them and the surfaces say so.
public enum HealthScoreDeltaReason: Codable, Sendable, Hashable {
    /// The server changed how it computes the score; the first delta across
    /// that seam is suppressed on purpose.
    case algorithmChanged
    /// A different set of pillars backed the score than last week — the two
    /// numbers are not like-for-like.
    case compositionChanged
    /// The first window that qualified at all — nothing before it to compare.
    case firstEligibilityWindow
    /// The move was smaller than the score's own noise floor.
    case belowNoiseFloor
    /// No previous window existed.
    case noPreviousWindow
    /// No current score to compare.
    case noCurrentScore
    /// A reason this client does not know yet.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "algorithm_changed": self = .algorithmChanged
        case "composition_changed": self = .compositionChanged
        case "first_eligibility_window": self = .firstEligibilityWindow
        case "below_noise_floor": self = .belowNoiseFloor
        case "no_previous_window": self = .noPreviousWindow
        case "no_current_score": self = .noCurrentScore
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .algorithmChanged: "algorithm_changed"
        case .compositionChanged: "composition_changed"
        case .firstEligibilityWindow: "first_eligibility_window"
        case .belowNoiseFloor: "below_noise_floor"
        case .noPreviousWindow: "no_previous_window"
        case .noCurrentScore: "no_current_score"
        case let .unknown(raw): raw
        }
    }

    /// `true` when the missing delta is about the **measurement**, not the
    /// person: the algorithm changed under the number, the pillar set changed,
    /// the first eligible window has no predecessor, or the move sat inside
    /// the noise floor. Surfaces must not narrate these as a change in the
    /// user's health.
    public var isMeasurementArtefact: Bool {
        switch self {
        case .algorithmChanged, .compositionChanged,
             .firstEligibilityWindow, .belowNoiseFloor:
            true
        case .noPreviousWindow, .noCurrentScore, .unknown:
            false
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

// MARK: - Rest Mode

/// **v1.18.1 P4 — the score-payload view of Rest Mode (server-authoritative).**
///
/// A compact, value-free annotation the server attaches when an
/// illness/condition episode is active, so the surface can *frame* the score
/// ("you were resting / recovering during this window") WITHOUT changing it.
/// Never a decrypted note, never a label, never a score adjustment — iOS
/// mirrors it verbatim (annotate-never-mutate).
///
/// The server sends `active: true` or omits the whole object; it never sends
/// `active: false`. Absence means "no Rest Mode", which is why the annotation
/// is an explanation and not a verdict.
///
/// **Defensive decode:** a present-but-shapeless object still resolves (missing
/// `since` stays `nil`, missing `episodeCount` defaults to `0`).
public struct RestModeAnnotation: Codable, Sendable, Hashable {
    /// Whether the account is in Rest Mode right now.
    public let active: Bool
    /// ISO onset of the earliest active episode — a calendar anchor only.
    public let since: Date?
    /// Number of active episodes contributing to Rest Mode. `0` when omitted.
    public let episodeCount: Int

    public init(active: Bool, since: Date?, episodeCount: Int) {
        self.active = active
        self.since = since
        self.episodeCount = episodeCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        episodeCount = (try? c.decode(Int.self, forKey: .episodeCount)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case active
        case since
        case episodeCount
    }
}
