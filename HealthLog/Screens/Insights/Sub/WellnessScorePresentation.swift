import Foundation

/// **I-2 — pure presentation model for the wellness-score rings + detail sheet.**
///
/// Maps a server `DerivedMetricDTO` onto the inputs `HLScoreRing` + the score
/// cards + the detail sheet need, WITHOUT any view dependency, so the
/// archetype/fraction/band/contributor resolution is unit-testable off the main
/// actor. HONEST-ONLY: every field derives from the server envelope; nothing is
/// fabricated. The confidence gate is explicit (``isInsufficient``).
enum WellnessScorePresentation {
    /// The render archetype for a derived metric — picks the ring shape + which
    /// detail layout the sheet uses.
    enum Archetype: Equatable {
        /// 0–100 quality score with a full ring + contributor breakdown
        /// (READINESS, SLEEP_SCORE).
        case scoreWithBreakdown
        /// 0–100 quality score, provenance-only (no sub-breakdown):
        /// STRAIN / RECOVERY / STRESS.
        case scoreProvenanceOnly
        /// VO₂max spectrum position → open-bottom gauge (FITNESS_AGE).
        case fitnessGauge
        /// Honest deviation COUNT — "Signale des Tages" (COINCIDENT_DEVIATION).
        /// Rendered as a count/summary, never a ring.
        case deviationCount
        /// Re-frame / band metrics that stay text cards on the overview
        /// (VASCULAR_AGE_DELTA, HRV_BALANCE) — not ring-promoted in I-2.
        case textReframe

        nonisolated static func resolve(metric: String) -> Archetype {
            switch metric {
            case "READINESS", "SLEEP_SCORE": .scoreWithBreakdown
            case "STRAIN_SCORE", "RECOVERY_SCORE", "STRESS_SCORE": .scoreProvenanceOnly
            case "FITNESS_AGE": .fitnessGauge
            case "COINCIDENT_DEVIATION": .deviationCount
            default: .textReframe
            }
        }

        /// Issue-2 — the five derived-score ids that carry a per-score
        /// `assessment` ("Einschätzung"), mirroring the server's
        /// `ASSESSABLE_DERIVED_SCORES`
        /// (`src/lib/insights/derived/derived-assessment.ts`). Used to skip the
        /// single-route assessment re-read for non-assessable metrics (gauge /
        /// count / re-frames never carry one).
        nonisolated static func isAssessable(_ metric: String) -> Bool {
            ["READINESS", "SLEEP_SCORE", "RECOVERY_SCORE", "STRAIN_SCORE", "STRESS_SCORE"].contains(metric)
        }
    }

    /// `true` when the server returned `insufficient` (or a non-ok status) for a
    /// metric — the calm "noch nicht genug Daten" gate, NOT a fabricated score.
    nonisolated static func isInsufficient(_ dto: DerivedMetricDTO) -> Bool {
        !dto.isOK || dto.value == nil
    }

    /// **v1.27.5 — DTO-aware archetype resolution.**
    ///
    /// RECOVERY_SCORE now carries an optional readiness-blend `components[]`
    /// breakdown (server v1.27.5; the COMPUTED recovery proxy IS the persisted
    /// readiness blend). When those contributors are present it renders the SAME
    /// factor-breakdown UI as READINESS / SLEEP_SCORE (`.scoreWithBreakdown`);
    /// when ABSENT — a watch-native recovery, which has no sub-scores — it stays
    /// provenance-only, so the source line ("your WHOOP recovery") shows instead
    /// of an empty breakdown. Every other metric keeps its static archetype.
    ///
    /// Pure (off-main-actor testable) so the promote-when-present /
    /// hide-when-absent gate is locked without a SwiftUI host.
    nonisolated static func archetype(for dto: DerivedMetricDTO) -> Archetype {
        let base = Archetype.resolve(metric: dto.metric)
        if dto.metric == "RECOVERY_SCORE", !rankedContributors(dto).isEmpty {
            return .scoreWithBreakdown
        }
        return base
    }

    /// **W-B187 #29 — recovery source authority (server-resolved).**
    ///
    /// `true` when the server resolved this `RECOVERY_SCORE` headline from a
    /// WHOOP-native recovery (vs the computed HRV proxy). The server v1.17 W2b
    /// decision makes WHOOP-native recovery canonical when a WHOOP recovery
    /// exists for the night, falling back to the computed proxy otherwise; iOS
    /// stays a thin renderer (no recompute) and only READS which source the
    /// server picked so the copy + explainer don't lie ("computed proxy" framing
    /// would be wrong on a WHOOP-native value).
    ///
    /// **Tolerant detection.** The server tags the backing inputs in
    /// `provenance.inputs`; a WHOOP-native recovery carries a WHOOP marker in
    /// that list. We match case-insensitively on a `WHOOP` substring so a future
    /// token spelling (`WHOOP_RECOVERY`, `WHOOP`) still reads as native, and an
    /// older server that omits the marker simply reads as the computed proxy
    /// (today's behaviour) — never fabricated, never misattributed.
    nonisolated static func isWhoopNativeRecovery(_ dto: DerivedMetricDTO) -> Bool {
        guard dto.metric == "RECOVERY_SCORE" else { return false }
        return dto.provenance.inputs.contains { $0.uppercased().contains("WHOOP") }
    }

    /// The 0…1 ring fill for a 0–100 composite score, or `nil` when there is no
    /// score (re-frames / counts). Clamped, never extrapolated.
    nonisolated static func ringFraction(_ dto: DerivedMetricDTO) -> Double? {
        guard let score = dto.value?.score else { return nil }
        return max(0, min(1, score / 100))
    }

    /// The 0…1 cap-dot position for the Cardio-Fitness (FITNESS_AGE) open-bottom
    /// gauge: places the real VO₂max within its server reference band so the
    /// needle reads "above"/"below" by position past the ticks. HONEST: with no
    /// VO₂max OR no reference band there is no defensible placement, so the cap
    /// sits mid-arc (0.5) while the value text still shows the real number (or
    /// "—"). Single source so the overview card AND the detail-sheet hero render
    /// the SAME position.
    nonisolated static func fitnessGaugeFraction(_ dto: DerivedMetricDTO) -> Double {
        guard let vo2 = dto.value?.vo2Max, let band = dto.value?.referenceBand else { return 0.5 }
        let span = max(0.0001, band.high - band.low)
        // Map [low−span/2 … high+span/2] → 0…1 so the band sits in the middle
        // third and "above"/"below" read by cap position past the ticks.
        let lo = band.low - span / 2
        let hi = band.high + span / 2
        return max(0, min(1, (vo2 - lo) / (hi - lo)))
    }

    /// v0.14.9 §2 — the 0…1 ring fill for the HRV-balance band ring. HRV balance
    /// carries NO 0–100 score, only a server band (`low` / `balanced` /
    /// `unbalanced`); the ring fill positions that band on the arc so "balanced"
    /// reads as a comfortable centred fill, `low`/`unbalanced` as off-centre.
    /// HONEST: the band is the server's own, never reinterpreted; the fraction is
    /// purely a visual placement of that band. `nil` ⇒ no band (calm gate).
    nonisolated static func hrvBalanceFraction(_ dto: DerivedMetricDTO) -> Double? {
        switch dto.value?.band {
        case "balanced": 0.66
        case "unbalanced": 0.9
        case "low": 0.33
        default: nil
        }
    }

    /// v0.14.9 §2 — the SHORT centre word for the HRV-balance ring. Kept terse so
    /// it fits the ring centre at the big metric font without truncating ("Even" /
    /// "High" / "Low"); the full band sentence is on the detail sheet + a11y. The
    /// short word maps the server band, never reinterprets it. `nil` ⇒ no band.
    nonisolated static func hrvBalanceValueText(_ dto: DerivedMetricDTO) -> String? {
        switch dto.value?.band {
        case "balanced": String(localized: "hrvBalance.short.balanced")
        case "unbalanced": String(localized: "hrvBalance.short.high")
        case "low": String(localized: "hrvBalance.short.low")
        default: nil
        }
    }

    /// v0.14.9 §2 — the 0…1 ring fill for the vascular-age years-delta ring,
    /// mirroring the Cardio-Fitness placement: a delta of 0 sits mid-arc, younger
    /// (negative) below, older (positive) above, with ±15 yr mapped to the arc
    /// ends so the fill reads the direction at a glance. HONEST: the delta is the
    /// server's own; the fraction is purely visual placement. Mid-arc (0.5) when
    /// the server carries no delta.
    nonisolated static func vascularDeltaFraction(_ dto: DerivedMetricDTO) -> Double {
        guard let years = dto.value?.deltaYears else { return 0.5 }
        // Younger arteries (negative delta) → fuller ring (toward 1); older →
        // lower fill. ±15 yr spans the arc; clamped beyond.
        let span = 15.0
        return max(0, min(1, 0.5 - years / (2 * span)))
    }

    /// The signal dot for a metric — derived from the server band where present,
    /// else from the 0–100 banding. `nil` ⇒ pure-mono ring (no dot).
    nonisolated static func signal(_ dto: DerivedMetricDTO) -> HLScoreRing.HLSignal? {
        if let band = dto.value?.band,
           let mapped = HLScoreRing.ScorePresentation.signal(forBand: band)
        {
            return mapped
        }
        if let score = dto.value?.score {
            return HLScoreRing.ScorePresentation.wellness(score: score).signal
        }
        return nil
    }

    /// The big centre value text for a score ring ("84"), or `nil`.
    nonisolated static func scoreValueText(_ dto: DerivedMetricDTO) -> String? {
        dto.value?.score.map { "\(Int($0.rounded()))" }
    }

    /// The ranked contributor rows for a `scoreWithBreakdown` metric, ordered
    /// present-first then by descending effective weight (web `rankByImpact`).
    /// Empty for the no-breakdown archetypes.
    nonisolated static func rankedContributors(_ dto: DerivedMetricDTO) -> [Contributor] {
        guard let raw = dto.value?.contributors else { return [] }
        return raw
            // v0.14.3 F4 — honest-only: hide null/absent contributors (e.g.
            // SLEEP_SCORE "Konsistenz"/"Zeitpunkt" return null under 3 nights)
            // so no empty "—" rows show. They reappear once data exists.
            .filter { $0.value != nil }
            .map { Contributor(key: $0.key, value: $0.value, weight: $0.weight) }
            .sorted { lhs, rhs in
                lhs.weight > rhs.weight
            }
    }

    // MARK: - Contributor row model

    /// One ranked contributor row, view-ready: localized label, 0…1 ring
    /// fraction (or nil = no data), and the deep-nav `MetricKind` (nil when no
    /// chartable metric page exists, e.g. mood / sleep sub-scores).
    struct Contributor: Equatable, Identifiable {
        let key: String
        let value: Double?
        let weight: Double
        var id: String {
            key
        }

        /// 0…1 ring fill for the compact contributor dot, or `nil` (no data).
        var fraction: Double? {
            value.map { max(0, min(1, $0 / 100)) }
        }

        /// The signal dot for the compact contributor ring.
        var signal: HLScoreRing.HLSignal? {
            value.map { HLScoreRing.ScorePresentation.wellness(score: $0).signal }
        }

        /// Localized contributor label (READINESS + SLEEP_SCORE keys).
        var label: String {
            switch key {
            // READINESS components.
            case "rhr": String(localized: "Resting heart rate")
            case "hrv": String(localized: "Heart rate variability")
            case "sleep": String(localized: "Sleep")
            case "respiratory": String(localized: "Respiratory rate")
            case "mood": String(localized: "Mood")
            // SLEEP_SCORE sub-scores.
            case "sufficiency": String(localized: "Duration")
            case "efficiency": String(localized: "Efficiency")
            case "consistency": String(localized: "Consistency")
            case "timing": String(localized: "Timing")
            case "composition": String(localized: "Stages")
            default: key
            }
        }

        /// The chartable metric page this contributor deep-navigates into, or
        /// `nil` for keys without an `InsightsMetricScreen` (sleep sub-scores,
        /// mood — mood is a special page reached differently).
        var deepNavKind: MetricKind? {
            switch key {
            case "rhr": .restingHeartRate
            case "hrv": .hrv
            case "sleep": .sleep
            case "respiratory": .respiratoryRate
            default: nil
            }
        }

        /// The value read-out ("82", "—" for missing). Mono, never fabricated.
        var valueText: String {
            value.map { "\(Int($0.rounded()))" } ?? "—"
        }
    }

    // MARK: - Deviation count ("Signale des Tages")

    /// The honest deviation-count summary for COINCIDENT_DEVIATION — a COUNT of
    /// vitals outside their personal band today, never a score, never a cause.
    struct DeviationSummary: Equatable {
        /// `true` when ≥2 vitals are outside band (the flag fired).
        let fired: Bool
        /// The out-of-band vital `MeasurementType`s (UPPER_SNAKE) — the
        /// contributing factors listed without ever naming a cause.
        let contributing: [String]
        /// Total banded vitals checked today.
        let checked: Int

        var contributingCount: Int {
            contributing.count
        }
    }

    /// Resolve the deviation summary from a COINCIDENT_DEVIATION envelope.
    nonisolated static func deviationSummary(_ dto: DerivedMetricDTO) -> DeviationSummary? {
        guard dto.metric == "COINCIDENT_DEVIATION", let value = dto.value else { return nil }
        return DeviationSummary(
            fired: value.fired ?? false,
            contributing: (value.contributing ?? []).map(\.type),
            checked: (value.vitals ?? []).count
        )
    }

    /// **v0.14.8 Item-3 (b184 M4) — the single "Signale des Tages" show predicate.**
    ///
    /// `deviationSummary` resolves to a non-nil summary even for the CALM state
    /// (`fired == false` / zero contributing vitals — the "all within range"
    /// sentence), so the section must NOT show on that. The whole section
    /// (heading + card + spacing) shows ONLY when a signal FIRED with ≥1
    /// contributing vital. Both SwiftUI call sites (the inline copy in
    /// ``InsightsScoreCardsBlock`` and the hoisted ``InsightsSignalsOfTheDaySection``)
    /// AND the unit test read THIS one predicate, so the gate can't drift in one
    /// place and not the other (the M4 divergence risk). Pure (off-main-actor
    /// testable) — no SwiftUI host needed.
    nonisolated static func showsSignalsSection(_ summary: DeviationSummary?) -> Bool {
        guard let summary else { return false }
        return summary.fired && summary.contributingCount > 0
    }

    /// Localized human label for a server vital `MeasurementType` (the small set
    /// the deviation card lists). Falls back to the raw token so an unmapped
    /// vital still reads honestly rather than blank.
    nonisolated static func vitalLabel(_ serverType: String) -> String {
        switch serverType {
        case "RESTING_HEART_RATE": String(localized: "Resting heart rate")
        case "HEART_RATE_VARIABILITY": String(localized: "Heart rate variability")
        case "RESPIRATORY_RATE": String(localized: "Respiratory rate")
        case "OXYGEN_SATURATION": String(localized: "Oxygen saturation")
        case "BODY_TEMPERATURE": String(localized: "Body temperature")
        case "SKIN_TEMPERATURE": String(localized: "Skin temperature")
        case "PULSE": String(localized: "Pulse")
        case "BLOOD_PRESSURE_SYS": String(localized: "Blood pressure")
        case "BLOOD_GLUCOSE": String(localized: "Blood glucose")
        default: serverType
        }
    }
}
