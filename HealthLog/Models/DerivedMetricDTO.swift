import Foundation

/// Wire-form mirror of `GET /api/insights/derived?metric=<ID>` (server
/// v1.10.0, route at `src/app/api/insights/derived/route.ts`, envelope
/// `src/lib/insights/derived/types.ts:Derived<T>`).
///
/// **The one consumption contract.** A discriminated union on `status`. The
/// server flattens it for the wire: `metric` tags it, `value`/`reason` are
/// nullable so iOS decodes ONE stable shape. Pattern-match `status` — never
/// recompute (`HONEST-ONLY`: render only what the server returns; fabricate
/// nothing client-side).
///
/// ```jsonc
/// { "metric": "READINESS", "status": "ok",
///   "value": { … metric-specific … },
///   "coverage": { requiredInputs, presentInputs, historyDays, missing },
///   "confidence": { score, band }, "reason": null,
///   "provenance": { inputs, source, windowDays, computedAt } }
/// ```
///
/// **Forward-compatible enum.** The server may add metric ids in a later
/// release; iOS treats unknown ids as inert (it only requests the ids it
/// renders) and ignores what it cannot place. A `422` (unknown id) / `404`
/// (route not deployed) maps to `nil` at the repository.
///
/// **Server-derived (paired only).** Pure server compute — no on-device
/// fallback — so the derived block hides in standalone / no-server.
public struct DerivedMetricDTO: Codable, Sendable, Equatable {
    /// The metric id this envelope describes (echoes the requested id).
    public let metric: String
    /// `"ok"` → `value` + `confidence` present; `"insufficient"` → `reason`
    /// present, value/confidence absent. Anything else is treated as
    /// insufficient (forward-compatible).
    public let status: String
    /// The metric-specific payload (only on `status == "ok"`).
    public let value: Value?
    /// Coverage envelope — present on BOTH arms so the gating state renders
    /// the same "track N more days" treatment instead of a blank.
    public let coverage: Coverage
    /// 0..100 score + band (only on `status == "ok"`).
    public let confidence: Confidence?
    /// Provenance/transparency envelope — present on both arms.
    public let provenance: Provenance
    /// Short machine reason on the `insufficient` arm (localise prose
    /// client-side); `nil` on `ok`.
    public let reason: String?
    /// **D1 — per-score "Einschätzung".** Server v1.14.0 additive field
    /// (`src/lib/insights/derived/derived-assessment.ts:DerivedAssessment`,
    /// `src/app/api/insights/derived/route.ts`): a short "why is this score what
    /// it is" explanation, keyed to the SAME requested id (only emitted for the
    /// per-score ids READINESS / SLEEP_SCORE / RECOVERY_SCORE / STRAIN_SCORE /
    /// STRESS_SCORE). `nil` for any other metric and whenever `status != "ok"`.
    /// Always non-empty when present (deterministic text fills it; warmer AI
    /// prose overrides it once cached). The `batch` route returns `null` by
    /// design. iOS self-suppresses on `nil`/empty (HONEST-ONLY — never
    /// fabricated). Decoded leniently (`decodeIfPresent`) so older servers that
    /// omit the field stay forward-compatible.
    public let assessment: Assessment?
    /// **v0.14.1 — warm-in-flight flag.** Mirrors the narrative route's
    /// `revalidating` contract (`NarrativeDTO.revalidating`): `true` when the
    /// server is still computing this score / assessment out of band (a cold
    /// first-login session where the daily derived compute has not landed yet),
    /// so the overview can show a calm "wird erstellt…" placeholder and schedule
    /// a bounded in-session re-poll instead of freezing the empty state until
    /// the next Berlin-day rollover. Tolerant decode (`decodeIfPresent`) — older
    /// servers that omit it leave it `nil`, which reads as "settled".
    public let revalidating: Bool?

    public init(
        metric: String,
        status: String,
        value: Value?,
        coverage: Coverage,
        confidence: Confidence?,
        provenance: Provenance,
        reason: String?,
        assessment: Assessment? = nil,
        revalidating: Bool? = nil
    ) {
        self.metric = metric
        self.status = status
        self.value = value
        self.coverage = coverage
        self.confidence = confidence
        self.provenance = provenance
        self.reason = reason
        self.assessment = assessment
        self.revalidating = revalidating
    }

    // MARK: - Codable (tolerant assessment)

    private enum CodingKeys: String, CodingKey {
        case metric, status, value, coverage, confidence, provenance, reason, assessment, revalidating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = try c.decode(String.self, forKey: .metric)
        status = try c.decode(String.self, forKey: .status)
        value = try c.decodeIfPresent(Value.self, forKey: .value)
        coverage = try c.decode(Coverage.self, forKey: .coverage)
        confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence)
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        // Tolerant: absent OR JSON `null` both decode to `nil`.
        assessment = try c.decodeIfPresent(Assessment.self, forKey: .assessment)
        revalidating = try c.decodeIfPresent(Bool.self, forKey: .revalidating)
    }

    // MARK: - Assessment (per-score Einschätzung)

    /// The additive per-score assessment envelope
    /// (`{ text, source, updatedAt }`). `source`/`updatedAt` are decoded
    /// leniently so a future server that drops one of them does not fail the
    /// whole envelope. iOS does NOT badge `source` (operator: no provenance
    /// badge needed) — it is kept for completeness only.
    public struct Assessment: Codable, Sendable, Equatable {
        /// Non-empty short explanation of why the score is what it is.
        public let text: String
        /// `"deterministic"` (always-on template) or `"ai"` (cached warm prose).
        /// Not surfaced in the UI.
        public let source: String?
        /// ISO timestamp the text was produced / last warmed.
        public let updatedAt: Date?

        public init(text: String, source: String? = nil, updatedAt: Date? = nil) {
            self.text = text
            self.source = source
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case text, source, updatedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        }
    }

    /// `true` when the value computed successfully (mirrors `isDerivedOk`).
    public var isOK: Bool {
        status == "ok"
    }

    // MARK: - Coverage

    public struct Coverage: Codable, Sendable, Equatable {
        /// Inputs the metric WANTS (its full input set).
        public let requiredInputs: Int
        /// Inputs actually present.
        public let presentInputs: Int
        /// Days of history backing the value — the gating floor.
        public let historyDays: Int
        /// Named inputs still missing — drives the "track X to sharpen" nudge.
        public let missing: [String]

        public init(requiredInputs: Int, presentInputs: Int, historyDays: Int, missing: [String]) {
            self.requiredInputs = requiredInputs
            self.presentInputs = presentInputs
            self.historyDays = historyDays
            self.missing = missing
        }
    }

    // MARK: - Confidence

    public struct Confidence: Codable, Sendable, Equatable {
        /// 0..100.
        public let score: Int
        /// `"high" | "medium" | "low" | "draft"`.
        public let band: String

        public init(score: Int, band: String) {
            self.score = score
            self.band = band
        }
    }

    // MARK: - Provenance

    public struct Provenance: Codable, Sendable, Equatable {
        /// Named inputs that actually backed the value.
        public let inputs: [String]
        /// Granularity the dominant read resolved against
        /// (`DAY | WEEK | MONTH | YEAR | live | none`).
        public let source: String
        /// Trailing window the value summarises, in days.
        public let windowDays: Int
        /// Compute time (ISO 8601 with offset) for the "as of" chip.
        public let computedAt: Date

        public init(inputs: [String], source: String, windowDays: Int, computedAt: Date) {
            self.inputs = inputs
            self.source = source
            self.windowDays = windowDays
            self.computedAt = computedAt
        }
    }

    // MARK: - Value (metric-specific, decoded leniently)

    // MARK: - Contributor (ranked score breakdown)

    /// One ranked contributor of a composite wellness score — the
    /// READINESS `components[]` rows (`{key,value,weight}`,
    /// `src/lib/insights/derived/readiness.ts:ReadinessComponent`) and the
    /// SLEEP_SCORE `subScores[]` rows
    /// (`src/lib/insights/derived/sleep-score.ts:SleepSubScore`). The two
    /// server arrays share an identical shape, so iOS decodes both into this
    /// one struct. `value` is `nil` when the input was missing (the server
    /// dropped it from the blend) — rendered as a "no data" contributor, never
    /// fabricated. `weight` is the EFFECTIVE weight after null-redistribution
    /// (0…1), the share the contributor actually carried in the composite.
    ///
    /// **The I-2 tap-through breakdown.** This is the row the detail sheet
    /// ranks (present-first, then by weight) and deep-navigates from.
    public struct Contributor: Codable, Sendable, Equatable {
        /// Server contributor key (`rhr/hrv/sleep/respiratory/mood` for
        /// READINESS; `sufficiency/efficiency/consistency/timing/composition`
        /// for SLEEP_SCORE). Mapped to a localized label + (where one exists) a
        /// deep-nav `MetricKind` client-side.
        public let key: String
        /// 0…100 contributor score, or `nil` when the input was missing.
        public let value: Double?
        /// Effective weight after null-redistribution, 0…1.
        public let weight: Double

        public init(key: String, value: Double?, weight: Double) {
            self.key = key
            self.value = value
            self.weight = weight
        }
    }

    // MARK: - VitalDeviation (Signale des Tages)

    /// One vital's standing against its personal band today — the
    /// COINCIDENT_DEVIATION `vitals[]` / `contributing[]` rows
    /// (`src/lib/insights/derived/coincident-deviation.ts:VitalDeviation`).
    /// Drives the honest "Signale des Tages" deviation-COUNT card (NOT a score,
    /// NOT AI). `outside == true` ⇒ this vital is one of the contributing
    /// factors; `direction` is `above/below/in`.
    public struct VitalDeviation: Codable, Sendable, Equatable {
        /// Server `MeasurementType` (UPPER_SNAKE, e.g. `RESTING_HEART_RATE`).
        public let type: String
        /// Today's value.
        public let value: Double
        /// Band center (median).
        public let center: Double
        public let low: Double
        public let high: Double
        /// `true` when today's value falls outside `[low, high]`.
        public let outside: Bool
        /// `above` / `below` (outside) or `in` (inside the band).
        public let direction: String

        public init(
            type: String,
            value: Double,
            center: Double,
            low: Double,
            high: Double,
            outside: Bool,
            direction: String
        ) {
            self.type = type
            self.value = value
            self.center = center
            self.low = low
            self.high = high
            self.outside = outside
            self.direction = direction
        }
    }

    /// The metric-specific `value` payload. The server returns a different
    /// shape per archetype; this struct decodes the union of fields the
    /// overview block surfaces, each optional, so one decoder covers every
    /// metric. Fields absent for a given metric stay `nil` — never
    /// fabricated. (Composite scores carry `score` + `band`; baselines carry
    /// `center/low/high`; re-frames carry `*Delta*` / `band`.)
    public struct Value: Codable, Sendable, Equatable {
        /// Composite scores (READINESS / SLEEP_SCORE / RECOVERY/STRESS/STRAIN).
        public let score: Double?
        /// Score minus the trailing-window mean (the wellness scores' Whoop/Oura
        /// "vs your baseline" trend). Server-computed (`WellnessScoreValue.trendDelta`),
        /// `nil` when the server has no prior window — never fabricated.
        public let trendDelta: Double?
        /// Band string as the server emits it for this metric
        /// (`green/yellow/red` for composites; `balanced/unbalanced/low` for
        /// HRV balance; etc.). Rendered as-is, never reinterpreted.
        public let band: String?

        // VITALS_BASELINE / HRV_BALANCE personal-typical-range band.
        public let center: Double?
        public let low: Double?
        public let high: Double?
        public let baselineLow: Double?
        public let baselineHigh: Double?

        // FITNESS_AGE / VASCULAR_AGE_DELTA re-frames (years).
        public let fitnessAgeDeltaYears: Double?
        public let deltaYears: Double?
        public let vo2Max: Double?
        public let vascularAge: Double?
        /// FITNESS_AGE age × sex reference band the placement used — drives the
        /// open-bottom gauge's band ticks. `nil` without demographics.
        public let referenceBand: ReferenceBand?

        // Ranked contributor breakdown (I-2). READINESS emits `components`,
        // SLEEP_SCORE emits `subScores` — same row shape. Both decode here; the
        // `contributors` accessor unifies them so callers never branch on which
        // array the server populated. STRAIN/RECOVERY/STRESS emit neither
        // (provenance-only) → both stay `nil`.
        public let components: [Contributor]?
        public let subScores: [Contributor]?

        // SAME_TIME_BASELINE (CU-30 / C5, server v1.34.0,
        // `src/lib/insights/derived/same-time-baseline.ts:240-259`). A
        // cumulative metric has no "latest reading", so the server compares
        // today's running total against the operator's own typical standing at
        // the SAME hour of day. Every field below is server-computed —
        // **nothing here is recomputed client-side, and no end-of-day forecast
        // is derived from it** (the server deliberately ships none). The typed
        // projection lives in `SameTimeBaseline.swift`; these raw slots exist so
        // ONE `Value` decoder still covers every metric.
        //
        // `unit`, `timezone`, `dateKey`, `asOfHour`, `todayValue`,
        // `typicalValue`, `typicalLow`, `typicalHigh`, `delta`, `band`,
        // `todayCurve`, `typicalCurve`, `baselineDays`, `windowDays` are all
        // non-null on the `ok` arm; `percentOfTypical` is nullable ON `ok`
        // (undefined ratio when the typical total at that hour is zero — normal
        // at 05:00, NOT a failure).
        public let type: String?
        public let unit: String?
        public let timezone: String?
        public let dateKey: String?
        /// The last COMPLETED local hour — real range 0…22 (never 23), so the
        /// curves are 1…23 points long, never 24.
        public let asOfHour: Int?
        public let todayValue: Double?
        public let typicalValue: Double?
        public let typicalLow: Double?
        public let typicalHigh: Double?
        public let delta: Double?
        public let percentOfTypical: Int?
        /// Cumulative running totals, hour `0 … asOfHour`, index-aligned with
        /// ``typicalCurve``. Bare numbers, never null.
        public let todayCurve: [Double]?
        /// Per-hour median across the window's usable days — same length, same
        /// index alignment, but no single real day.
        public let typicalCurve: [Double]?
        public let baselineDays: Int?
        public let windowDays: Int?

        /// COINCIDENT_DEVIATION ("Signale des Tages") — honest deviation count.
        /// `true` when ≥2 vitals are outside their personal band today.
        public let fired: Bool?
        /// All banded vitals checked today.
        public let vitals: [VitalDeviation]?
        /// Just the out-of-band vitals (the contributing factors).
        public let contributing: [VitalDeviation]?

        /// The unified ranked contributor list for a composite score —
        /// READINESS `components` OR SLEEP_SCORE `subScores`, whichever the
        /// server populated. `nil` for the no-breakdown scores
        /// (STRAIN/RECOVERY/STRESS) so the sheet shows provenance instead.
        public var contributors: [Contributor]? {
            components ?? subScores
        }

        public struct ReferenceBand: Codable, Sendable, Equatable {
            public let low: Double
            public let high: Double

            public init(low: Double, high: Double) {
                self.low = low
                self.high = high
            }
        }

        public init(
            score: Double? = nil,
            trendDelta: Double? = nil,
            band: String? = nil,
            center: Double? = nil,
            low: Double? = nil,
            high: Double? = nil,
            baselineLow: Double? = nil,
            baselineHigh: Double? = nil,
            fitnessAgeDeltaYears: Double? = nil,
            deltaYears: Double? = nil,
            vo2Max: Double? = nil,
            vascularAge: Double? = nil,
            referenceBand: ReferenceBand? = nil,
            components: [Contributor]? = nil,
            subScores: [Contributor]? = nil,
            type: String? = nil,
            unit: String? = nil,
            timezone: String? = nil,
            dateKey: String? = nil,
            asOfHour: Int? = nil,
            todayValue: Double? = nil,
            typicalValue: Double? = nil,
            typicalLow: Double? = nil,
            typicalHigh: Double? = nil,
            delta: Double? = nil,
            percentOfTypical: Int? = nil,
            todayCurve: [Double]? = nil,
            typicalCurve: [Double]? = nil,
            baselineDays: Int? = nil,
            windowDays: Int? = nil,
            fired: Bool? = nil,
            vitals: [VitalDeviation]? = nil,
            contributing: [VitalDeviation]? = nil
        ) {
            self.score = score
            self.trendDelta = trendDelta
            self.band = band
            self.center = center
            self.low = low
            self.high = high
            self.baselineLow = baselineLow
            self.baselineHigh = baselineHigh
            self.fitnessAgeDeltaYears = fitnessAgeDeltaYears
            self.deltaYears = deltaYears
            self.vo2Max = vo2Max
            self.vascularAge = vascularAge
            self.referenceBand = referenceBand
            self.components = components
            self.subScores = subScores
            self.type = type
            self.unit = unit
            self.timezone = timezone
            self.dateKey = dateKey
            self.asOfHour = asOfHour
            self.todayValue = todayValue
            self.typicalValue = typicalValue
            self.typicalLow = typicalLow
            self.typicalHigh = typicalHigh
            self.delta = delta
            self.percentOfTypical = percentOfTypical
            self.todayCurve = todayCurve
            self.typicalCurve = typicalCurve
            self.baselineDays = baselineDays
            self.windowDays = windowDays
            self.fired = fired
            self.vitals = vitals
            self.contributing = contributing
        }
    }
}
