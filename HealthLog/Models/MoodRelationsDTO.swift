import Foundation

/// Wire-form mirror of the **mood "relations"** slices on
/// `GET /api/mood/insights` (server v1.11.5, `src/lib/insights/mood-aggregates.ts`
/// → `MoodAggregates`, serialised verbatim by `src/app/api/mood/insights/route.ts`
/// via `apiSuccess(result)` — camelCase, the iOS `JSONDecoder.hlDefault` keeps
/// the keys as-is).
///
/// **What it serves (the Daylio payoff).** Two observational slices:
///  - **`tagInfluence`** — per tag, the average daily mood on days the tag is
///    PRESENT vs ABSENT, the `delta`, both group day-counts, and a `confidence`
///    band (`low`/`medium`/`high`) from a Welch t-test with a ≥5-day floor per
///    side. Split into `flat` (free-text) + `structured` (taxonomy) axes.
///  - **`betterDays`** — one ranked board folding the tag deltas AND the
///    mood × health-metric correlations into an effect-size-ranked, confidence-
///    gated list of what is associated with better-mood days.
///
/// **Tolerant + additive.** This struct intentionally decodes ONLY the two new
/// keys; the route returns the whole `MoodAggregates` payload (heatmap,
/// distribution, weekday, narratives, …) which iOS already computes
/// client-side off raw entries — those keys are ignored here. A missing slice
/// (older server, or a payload that pre-dates v1.11.5) decodes to an empty
/// value, never an error, so the cards self-suppress instead of crashing.
///
/// **ASSOCIATION, NEVER CAUSE.** Every row is a statistical association over a
/// short window. The UI carries the standing "association, not cause" framing
/// and adds no causal/clinical language (MDR doctrine).
public struct MoodRelationsResponse: Codable, Sendable, Equatable {
    /// Tag "Influence on Mood" — with-vs-without daily-mean delta + Welch
    /// confidence band, per frequent flat / structured tag.
    public let tagInfluence: TagInfluence
    /// Unified "what's associated with your better days" board.
    public let betterDays: [BetterDayFactor]
    /// v0.14.8 — the RATED-factor × metric crosstab (`factorCrosstab`, server
    /// v1.14.0): per RATED factor, the mean of a tracked metric on the days the
    /// factor was rated LOW vs HIGH (median split, inverse-aware, Welch + FDR).
    /// This is the actual analytical USE of the slider rating VALUES. Tolerant:
    /// a pre-v1.14.0 payload decodes to `[]`.
    public let factorCrosstab: [FactorMetricCrosstabRow]

    public init(
        tagInfluence: TagInfluence = .empty,
        betterDays: [BetterDayFactor] = [],
        factorCrosstab: [FactorMetricCrosstabRow] = []
    ) {
        self.tagInfluence = tagInfluence
        self.betterDays = betterDays
        self.factorCrosstab = factorCrosstab
    }

    /// Tolerant additive decode: a payload missing a slice (pre-v1.11.5 server,
    /// or pre-v1.14.0 for `factorCrosstab`) yields the empty value rather than
    /// throwing, so the cards degrade to their calm empty state instead of
    /// erroring the whole page.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagInfluence = try container.decodeIfPresent(TagInfluence.self, forKey: .tagInfluence) ?? .empty
        betterDays = try container.decodeIfPresent([BetterDayFactor].self, forKey: .betterDays) ?? []
        factorCrosstab = try container.decodeIfPresent([FactorMetricCrosstabRow].self, forKey: .factorCrosstab) ?? []
    }
}

public extension MoodRelationsResponse {
    /// True when no slice carries a single row — the page hides the whole
    /// relations region and shows the calm "not enough data yet" empty state.
    var isEmpty: Bool {
        tagInfluence.isEmpty && betterDays.isEmpty && factorCrosstab.isEmpty
    }
}

/// One **RATED factor × metric** crosstab row (`factorCrosstab`, server
/// v1.14.0, `mood-aggregates.ts` `FactorMetricCrosstabRow`). On the days a
/// RATED factor was scored LOW (below its own median) vs HIGH, the mean of a
/// tracked metric — the split runs on the inverse-flipped series so a "low" row
/// always reads as a worse day regardless of polarity.
///
/// **ASSOCIATION, NEVER CAUSE.** A short-window Welch comparison, FDR-corrected
/// across the tested family. The UI carries the standing "association, not
/// cause" caption and adds no causal/clinical language (MDR doctrine).
public struct FactorMetricCrosstabRow: Codable, Sendable, Equatable, Identifiable {
    /// Stable RATED-factor key (e.g. `factor_work`, `factor_sleep_quality`).
    public let factor: String
    /// i18n label key for the factor.
    public let labelKey: String
    /// Parent category key, for grouping/icon.
    public let categoryKey: String
    /// Lucide icon name, or `nil`.
    public let icon: String?
    /// `true` when the factor is inverse-scaled (sadness / stress). The split
    /// already ran on the flipped series, so "low" always means a worse day.
    public let inverse: Bool
    /// Which metric channel this row compares against (`sleepDuration`,
    /// `steps`, `restingHeartRate`, `heartRateVariability`, `weight`,
    /// `bloodPressureSystolic`).
    public let metricKey: String
    /// Display-unit hint (`hours`/`steps`/`bpm`/`ms`/`kg`/`mmHg`).
    public let display: String
    /// Pairing mode (`sameDay`/`nextDay`).
    public let mode: String
    /// Days the factor was rated LOW (below its median) with a paired metric.
    public let lowDays: Int
    /// Days the factor was rated HIGH (at/above its median) with a paired metric.
    public let highDays: Int
    /// Mean metric on low-factor days (display unit).
    public let lowAvg: Double
    /// Mean metric on high-factor days (display unit).
    public let highAvg: Double
    /// `lowAvg − highAvg` (display unit). Negative = vital runs lower on low days.
    public let delta: Double
    /// Welch two-sided p-value (transparency only).
    public let pValue: Double
    /// Benjamini-Hochberg adjusted q-value across the tested family.
    public let qValue: Double
    /// Confidence band (p + min per-group day count).
    public let confidence: MoodConfidence

    /// Identity for `ForEach` — factor + metric is unique on the board.
    public var id: String {
        "\(factor):\(metricKey)"
    }

    /// Smaller of the two group day-counts — the honest sample size the
    /// comparison rests on.
    public var minGroupDays: Int {
        min(lowDays, highDays)
    }

    public init(
        factor: String,
        labelKey: String,
        categoryKey: String,
        icon: String? = nil,
        inverse: Bool,
        metricKey: String,
        display: String,
        mode: String,
        lowDays: Int,
        highDays: Int,
        lowAvg: Double,
        highAvg: Double,
        delta: Double,
        pValue: Double,
        qValue: Double,
        confidence: MoodConfidence
    ) {
        self.factor = factor
        self.labelKey = labelKey
        self.categoryKey = categoryKey
        self.icon = icon
        self.inverse = inverse
        self.metricKey = metricKey
        self.display = display
        self.mode = mode
        self.lowDays = lowDays
        self.highDays = highDays
        self.lowAvg = lowAvg
        self.highAvg = highAvg
        self.delta = delta
        self.pValue = pValue
        self.qValue = qValue
        self.confidence = confidence
    }
}

/// The two tag-influence axes the server ranks separately. `flat` is free-text
/// tags (rendered verbatim), `structured` is the curated taxonomy (rendered via
/// the mood-tag catalog: icon + localized label).
public struct TagInfluence: Codable, Sendable, Equatable {
    public let flat: [TagInfluenceRow]
    public let structured: [TagInfluenceRow]

    public init(flat: [TagInfluenceRow] = [], structured: [TagInfluenceRow] = []) {
        self.flat = flat
        self.structured = structured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flat = try container.decodeIfPresent([TagInfluenceRow].self, forKey: .flat) ?? []
        structured = try container.decodeIfPresent([TagInfluenceRow].self, forKey: .structured) ?? []
    }

    public static let empty = TagInfluence()

    public var isEmpty: Bool {
        flat.isEmpty && structured.isEmpty
    }
}

/// Discrete confidence band the UI chip renders. Mirrors the server's
/// `InfluenceConfidence` (`low`/`medium`/`high`) — derived from the Welch
/// p-value AND the smaller per-group sample size, so a small p on tiny groups
/// is honestly downgraded (NOT fake precision).
public enum MoodConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high

    /// Tolerant decode — an unknown future band falls back to `low` (the most
    /// conservative reading) rather than throwing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MoodConfidence(rawValue: raw) ?? .low
    }
}

/// One tag's with-vs-without mood comparison. For a `structured` tag,
/// `labelKey`/`categoryKey`/`icon` carry the taxonomy metadata so the row can
/// render the localized label + its catalog icon; for a `flat` tag they are
/// `nil` and `tag` is the free-text string itself.
public struct TagInfluenceRow: Codable, Sendable, Equatable, Identifiable {
    /// Stable tag key. For flat tags this is the free-text string.
    public let tag: String
    /// i18n label key for a structured tag (`mood.tag.happy`); `nil` for flat.
    public let labelKey: String?
    /// Parent category key for a structured tag (`feelings`); `nil` for flat.
    public let categoryKey: String?
    /// Lucide icon name for a structured tag; `nil` for flat / unset.
    public let icon: String?
    /// Days the tag was PRESENT (daily-mean convention).
    public let withDays: Int
    /// Days the tag was ABSENT over the same window (the counterfactual).
    public let withoutDays: Int
    /// Mean of daily means on days the tag was present.
    public let withAvg: Double
    /// Mean of daily means on days the tag was absent.
    public let withoutAvg: Double
    /// `withAvg − withoutAvg`. Positive = higher mood WITH the tag.
    public let delta: Double
    /// Welch two-sided p-value for the difference of means (transparency only).
    public let pValue: Double
    /// Confidence band derived from p-value + per-group sample size.
    public let confidence: MoodConfidence

    /// Identity for `ForEach` — the tag key is unique within an axis.
    public var id: String {
        tag
    }

    public init(
        tag: String,
        labelKey: String? = nil,
        categoryKey: String? = nil,
        icon: String? = nil,
        withDays: Int,
        withoutDays: Int,
        withAvg: Double,
        withoutAvg: Double,
        delta: Double,
        pValue: Double,
        confidence: MoodConfidence
    ) {
        self.tag = tag
        self.labelKey = labelKey
        self.categoryKey = categoryKey
        self.icon = icon
        self.withDays = withDays
        self.withoutDays = withoutDays
        self.withAvg = withAvg
        self.withoutAvg = withoutAvg
        self.delta = delta
        self.pValue = pValue
        self.confidence = confidence
    }
}

public extension TagInfluenceRow {
    /// `delta ≥ 0` — the tag goes WITH higher mood. Drives glyph + sign only,
    /// never hue (monochrome).
    var isPositive: Bool {
        delta >= 0
    }

    /// Smaller of the two group day-counts — the honest sample size the
    /// comparison rests on (the side that can fail the ≥5-day floor first).
    var minGroupDays: Int {
        min(withDays, withoutDays)
    }
}

/// One ranked factor on the "better days" board. Either a `tag`
/// (`delta` = the mood-point swing) or a `metric` (`r` = the Pearson
/// correlation). `direction` tells the UI whether the factor goes with higher
/// or lower mood; the standing "association, not cause" caption rides the
/// whole board.
public struct BetterDayFactor: Codable, Sendable, Equatable, Identifiable {
    /// Whether this factor is a mood TAG or a tracked health METRIC.
    public enum Source: String, Codable, Sendable, Equatable {
        case tag
        case metric

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .tag
        }
    }

    /// `up` = associated with HIGHER mood; `down` = with LOWER mood.
    public enum Direction: String, Codable, Sendable, Equatable {
        case up
        case down

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Direction(rawValue: raw) ?? .up
        }
    }

    public let source: Source
    /// Tag key OR correlation channel key (`sleep`/`steps`/`pulse`/`weight`/
    /// `bloodPressureSystolic`).
    public let key: String
    /// i18n label key for a structured tag; `nil` for flat tags / metrics.
    public let labelKey: String?
    /// Parent category key for a structured tag; `nil` otherwise.
    public let categoryKey: String?
    /// Lucide icon name for a structured tag; `nil` otherwise.
    public let icon: String?
    public let direction: Direction
    /// Sample count behind the factor (tag: smaller group; metric: paired n).
    public let n: Int
    public let confidence: MoodConfidence
    /// Raw mood-point delta for a tag factor; `nil` for a metric factor.
    public let delta: Double?
    /// Raw Pearson `r` for a metric factor; `nil` for a tag factor.
    public let r: Double?

    /// Identity for `ForEach` — the source + key pair is unique on the board.
    public var id: String {
        "\(source.rawValue):\(key)"
    }

    public init(
        source: Source,
        key: String,
        labelKey: String? = nil,
        categoryKey: String? = nil,
        icon: String? = nil,
        direction: Direction,
        n: Int,
        confidence: MoodConfidence,
        delta: Double? = nil,
        r: Double? = nil
    ) {
        self.source = source
        self.key = key
        self.labelKey = labelKey
        self.categoryKey = categoryKey
        self.icon = icon
        self.direction = direction
        self.n = n
        self.confidence = confidence
        self.delta = delta
        self.r = r
    }
}

public extension BetterDayFactor {
    /// `direction == .up` — the factor goes WITH higher mood. Drives glyph +
    /// sign only, never hue (monochrome).
    var isPositive: Bool {
        direction == .up
    }
}
