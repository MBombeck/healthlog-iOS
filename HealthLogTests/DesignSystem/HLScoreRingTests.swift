@testable import HealthLog
import Testing

/// **I-2** — locks the pure presentation contracts behind the monochrome
/// `HLScoreRing` + the wellness-score cards / detail sheet: the band → signal +
/// tick logic, the confidence gate, the contributor ranking, and the
/// contributor → metric deep-nav mapping. All exercised off the main actor (no
/// SwiftUI host) — only the pure `static`/`nonisolated` resolvers are touched.
@Suite("HLScoreRing — band / tick / signal + wellness presentation")
struct HLScoreRingTests {
    // MARK: - HLScoreRing.ScorePresentation (band → signal + ticks)

    @Test("wellness banding — ≥70 green/.ok, 40–69 yellow/.warn, <40 red/.bad")
    func wellnessBanding() {
        #expect(HLScoreRing.ScorePresentation.wellness(score: 84).signal == .ok)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 70).signal == .ok)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 69).signal == .warn)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 40).signal == .warn)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 39).signal == .bad)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 0).signal == .bad)
    }

    @Test("wellness fraction — score / 100, clamped, never extrapolated")
    func wellnessFraction() {
        #expect(HLScoreRing.ScorePresentation.wellness(score: 84).fraction == 0.84)
        #expect(HLScoreRing.ScorePresentation.wellness(score: 150).fraction == 1.0)
        #expect(HLScoreRing.ScorePresentation.wellness(score: -10).fraction == 0.0)
    }

    @Test("tick set — canonical band cutoffs at 0.40 / 0.70")
    func canonicalTicks() {
        #expect(HLScoreRing.ScorePresentation.wellness(score: 50).ticks == [0.40, 0.70])
    }

    @Test("band string → signal (server band is authoritative)")
    func bandStringMapping() {
        #expect(HLScoreRing.ScorePresentation.signal(forBand: "green") == .ok)
        #expect(HLScoreRing.ScorePresentation.signal(forBand: "yellow") == .warn)
        #expect(HLScoreRing.ScorePresentation.signal(forBand: "red") == .bad)
        // Unknown / non-composite band → no fabricated signal dot.
        #expect(HLScoreRing.ScorePresentation.signal(forBand: "balanced") == nil)
        #expect(HLScoreRing.ScorePresentation.signal(forBand: nil) == nil)
    }

    // MARK: - Composed VoiceOver value (a11y P1+P2)

    @Test("a11y value — composes value + band word + signal meaning (not bare \"84\")")
    func composedAccessibilityValue() {
        // The detail-sheet hero case: value "84" + band word "Ready" + .ok dot.
        // Locale-agnostic: compose against the SAME localized signal word so the
        // test passes under any catalog language (CI runs in DE here).
        let okWord = HLScoreRing.HLSignal.ok.accessibilityWord
        let composed = HLScoreRing.composedAccessibilityValue(
            value: "84", label: "Ready", signal: .ok, fraction: 0.84
        )
        #expect(composed.contains("84"))
        #expect(composed.contains("Ready"))
        #expect(composed.contains(okWord)) // signal MEANING is conveyed
        #expect(composed == "84, Ready, \(okWord)")

        // Each signal maps to a DISTINCT, non-empty word (the dot meaning).
        let warn = HLScoreRing.HLSignal.warn.accessibilityWord
        let bad = HLScoreRing.HLSignal.bad.accessibilityWord
        #expect(!okWord.isEmpty && !warn.isEmpty && !bad.isEmpty)
        #expect(Set([okWord, warn, bad]).count == 3)
    }

    @Test("a11y value — graceful when only some parts present")
    func composedAccessibilityValuePartial() {
        // Value only (compact / no band, no signal) → just the value.
        #expect(HLScoreRing.composedAccessibilityValue(value: "42", label: nil, signal: nil, fraction: 0.42) == "42")
        // Nothing at all → percentage fallback (compact contributor dots).
        // Locale-agnostic: the resolved fallback must contain the number.
        let fallback = HLScoreRing.composedAccessibilityValue(value: nil, label: nil, signal: nil, fraction: 0.6)
        #expect(fallback.contains("60"))
        // Value + signal, no band word → "value, <signal word>".
        let badWord = HLScoreRing.HLSignal.bad.accessibilityWord
        #expect(
            HLScoreRing.composedAccessibilityValue(value: "30", label: nil, signal: .bad, fraction: 0.3)
                == "30, \(badWord)"
        )
    }

    // MARK: - Test fixtures

    private static func cov() -> DerivedMetricDTO.Coverage {
        .init(requiredInputs: 5, presentInputs: 4, historyDays: 21, missing: [])
    }

    private static func prov() -> DerivedMetricDTO.Provenance {
        .init(inputs: ["RESTING_HEART_RATE"], source: "DAY", windowDays: 30, computedAt: .now)
    }

    private static func dto(metric: String, value: DerivedMetricDTO.Value?, status: String = "ok") -> DerivedMetricDTO {
        DerivedMetricDTO(
            metric: metric, status: status, value: value,
            coverage: cov(), confidence: value == nil ? nil : .init(score: 78, band: "high"),
            provenance: prov(), reason: value == nil ? "insufficient_components" : nil
        )
    }

    // MARK: - WellnessScorePresentation — archetype + gate

    @Test("archetype — score/gauge/count/reframe resolution")
    func archetypeResolution() {
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "READINESS") == .scoreWithBreakdown)
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "SLEEP_SCORE") == .scoreWithBreakdown)
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "STRAIN_SCORE") == .scoreProvenanceOnly)
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "FITNESS_AGE") == .fitnessGauge)
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "COINCIDENT_DEVIATION") == .deviationCount)
        #expect(WellnessScorePresentation.Archetype.resolve(metric: "HRV_BALANCE") == .textReframe)
    }

    @Test("confidence gate — insufficient arm is honestly gated (no fake score)")
    func confidenceGate() {
        let insufficient = Self.dto(metric: "READINESS", value: nil, status: "insufficient")
        #expect(WellnessScorePresentation.isInsufficient(insufficient))
        // No score / fraction / signal fabricated for the gated arm.
        #expect(WellnessScorePresentation.ringFraction(insufficient) == nil)
        #expect(WellnessScorePresentation.scoreValueText(insufficient) == nil)
        #expect(WellnessScorePresentation.signal(insufficient) == nil)

        // An ok-with-value arm is NOT gated.
        let ok = Self.dto(metric: "READINESS", value: .init(score: 82, band: "green"))
        #expect(!WellnessScorePresentation.isInsufficient(ok))
        #expect(WellnessScorePresentation.ringFraction(ok) == 0.82)
        #expect(WellnessScorePresentation.scoreValueText(ok) == "82")
        #expect(WellnessScorePresentation.signal(ok) == .ok)
    }

    // MARK: - Cardio-Fitness gauge fraction (H1 — real needle position)

    @Test("fitness gauge fraction — VO₂max placed within reference band, real position")
    func fitnessGaugeFraction() {
        // band low 35 / high 45 → span 10 → mapped window [30 … 50].
        // A VO₂max at the band centre (40) lands mid-arc.
        let centre = Self.dto(
            metric: "FITNESS_AGE",
            value: .init(vo2Max: 40, referenceBand: .init(low: 35, high: 45))
        )
        #expect(WellnessScorePresentation.fitnessGaugeFraction(centre) == 0.5)

        // At the window floor (30) → 0; at the ceiling (50) → 1; clamped beyond.
        let low = Self.dto(metric: "FITNESS_AGE", value: .init(vo2Max: 30, referenceBand: .init(low: 35, high: 45)))
        let high = Self.dto(metric: "FITNESS_AGE", value: .init(vo2Max: 50, referenceBand: .init(low: 35, high: 45)))
        let way = Self.dto(metric: "FITNESS_AGE", value: .init(vo2Max: 80, referenceBand: .init(low: 35, high: 45)))
        #expect(WellnessScorePresentation.fitnessGaugeFraction(low) == 0.0)
        #expect(WellnessScorePresentation.fitnessGaugeFraction(high) == 1.0)
        #expect(WellnessScorePresentation.fitnessGaugeFraction(way) == 1.0)

        // A real value above the band centre reads ABOVE mid-arc (the needle MOVES).
        let above = Self.dto(metric: "FITNESS_AGE", value: .init(vo2Max: 44, referenceBand: .init(low: 35, high: 45)))
        #expect(WellnessScorePresentation.fitnessGaugeFraction(above) > 0.5)
    }

    @Test("fitness gauge fraction — honest mid-arc when no VO₂max or no band")
    func fitnessGaugeFractionHonestGate() {
        // No reference band → no defensible placement → mid-arc (0.5).
        let noBand = Self.dto(metric: "FITNESS_AGE", value: .init(vo2Max: 42))
        #expect(WellnessScorePresentation.fitnessGaugeFraction(noBand) == 0.5)
        // No VO₂max → mid-arc (0.5), value text shows "—" elsewhere.
        let noVo2 = Self.dto(metric: "FITNESS_AGE", value: .init(referenceBand: .init(low: 35, high: 45)))
        #expect(WellnessScorePresentation.fitnessGaugeFraction(noVo2) == 0.5)
    }

    // MARK: - Contributor ranking + deep-nav

    @Test("contributors — null-value rows hidden (F4), present rows by descending weight")
    func contributorRanking() {
        let value = DerivedMetricDTO.Value(
            score: 78, band: "green",
            components: [
                .init(key: "respiratory", value: nil, weight: 0), // v0.14.3 F4 → hidden
                .init(key: "mood", value: 66, weight: 0.13),
                .init(key: "rhr", value: 90, weight: 0.29),
                .init(key: "hrv", value: 71, weight: 0.29)
            ]
        )
        let ranked = WellnessScorePresentation.rankedContributors(Self.dto(metric: "READINESS", value: value))
        // v0.14.3 F4 — the null-value contributor ("respiratory") is dropped, so no
        // empty "—" row shows; only present rows remain, ordered by descending weight.
        #expect(ranked.count == 3)
        #expect(ranked.allSatisfy { $0.value != nil })
        #expect(!ranked.contains { $0.key == "respiratory" })
        #expect(ranked.map(\.key) == ["rhr", "hrv", "mood"])
    }

    @Test("contributor deep-nav — readiness keys map to chartable metric kinds")
    func contributorDeepNav() {
        func nav(_ key: String) -> MetricKind? {
            WellnessScorePresentation.Contributor(key: key, value: 80, weight: 0.25).deepNavKind
        }
        #expect(nav("rhr") == .restingHeartRate)
        #expect(nav("hrv") == .hrv)
        #expect(nav("sleep") == .sleep)
        #expect(nav("respiratory") == .respiratoryRate)
        // mood has no chartable InsightsMetricScreen → no deep-nav (special page).
        #expect(nav("mood") == nil)
        // sleep sub-scores are not chartable metrics on their own.
        #expect(nav("sufficiency") == nil)
    }

    @Test("contributor fraction + signal — derived honestly from the value")
    func contributorFractionSignal() {
        let present = WellnessScorePresentation.Contributor(key: "rhr", value: 90, weight: 0.29)
        #expect(present.fraction == 0.90)
        #expect(present.signal == .ok)
        let missing = WellnessScorePresentation.Contributor(key: "respiratory", value: nil, weight: 0)
        #expect(missing.fraction == nil)
        #expect(missing.signal == nil)
    }

    // MARK: - Ring/text dedup robustness (M3)

    @Test("ring-promoted dedup — promoted set = the rings + gauge + count, single source")
    func ringPromotedDedup() {
        let promoted = InsightsScoreCardsBlock.ringPromotedIDs
        // Every ordered ring score is promoted (so it drops from the text lane).
        for id in InsightsScoreCardsBlock.ringScoreOrder {
            #expect(promoted.contains(id))
        }
        // The gauge + delta/band rings + count IDs are promoted too — derived
        // from the same source the block actually renders, so none can vanish nor
        // double-render.
        #expect(promoted.contains(InsightsScoreCardsBlock.gaugeID))
        #expect(promoted.contains(InsightsScoreCardsBlock.vascularID))
        #expect(promoted.contains(InsightsScoreCardsBlock.hrvBalanceID))
        #expect(promoted.contains(InsightsScoreCardsBlock.deviationID))
        // The promoted set is EXACTLY the rendered IDs (no stale extras that
        // would silently drop a metric from the text lane while no ring shows).
        let expected = Set(InsightsScoreCardsBlock.ringScoreOrder)
            .union([
                InsightsScoreCardsBlock.gaugeID,
                InsightsScoreCardsBlock.vascularID,
                InsightsScoreCardsBlock.hrvBalanceID,
                InsightsScoreCardsBlock.deviationID
            ])
        #expect(promoted == expected)
        // v0.14.9 §2 — EVERY tile-able re-frame is now ring-promoted; the "More
        // from your data" text lane is empty, so both join the promoted set.
        #expect(promoted.contains("HRV_BALANCE"))
        #expect(promoted.contains("VASCULAR_AGE_DELTA"))
    }

    // MARK: - Issue-1 — empty score cards are hidden (no creepy black card)

    @Test("renderable score gate — only an ok arm WITH a value renders a tile")
    func renderableScoreGate() {
        // An `ok` arm with a real value → renders.
        let ok = Self.dto(metric: "READINESS", value: .init(score: 80, band: "green"))
        #expect(InsightsScoreCardsBlock.isRenderableScore(ok))

        // The `insufficient` arm (no value) → HIDDEN (was the black "—" card).
        let insufficient = Self.dto(metric: "READINESS", value: nil, status: "insufficient")
        #expect(!InsightsScoreCardsBlock.isRenderableScore(insufficient))

        // An `ok` status but nil value (defensive) → still hidden.
        let okNoValue = Self.dto(metric: "READINESS", value: nil, status: "ok")
        #expect(!InsightsScoreCardsBlock.isRenderableScore(okNoValue))

        // Absent DTO → hidden.
        #expect(!InsightsScoreCardsBlock.isRenderableScore(nil))
    }

    // MARK: - Issue-2 — per-score assessment (Einschätzung) is assessable set

    @Test("assessable scores — the five derived-score ids carry an Einschätzung")
    func assessableScores() {
        for id in ["READINESS", "SLEEP_SCORE", "RECOVERY_SCORE", "STRAIN_SCORE", "STRESS_SCORE"] {
            #expect(WellnessScorePresentation.Archetype.isAssessable(id))
        }
        // Gauge / count / re-frames never carry a per-score assessment.
        #expect(!WellnessScorePresentation.Archetype.isAssessable("FITNESS_AGE"))
        #expect(!WellnessScorePresentation.Archetype.isAssessable("COINCIDENT_DEVIATION"))
        #expect(!WellnessScorePresentation.Archetype.isAssessable("HRV_BALANCE"))
        #expect(!WellnessScorePresentation.Archetype.isAssessable("VASCULAR_AGE_DELTA"))
    }

    // MARK: - Issue-3 — centre value scales down only for 3 digits

    @Test("centre value scale floor — fits \"100\" on one line, leaves 2-digit room")
    func centreValueScaleFloor() {
        // The floor must be small enough that a 3-digit number ("100", 3 chars)
        // fits where a 2-digit one ("84", 2 chars) sat: 2/3 ≈ 0.667 is the exact
        // width ratio, so the floor must be ≤ that. It must not be so low that
        // numbers vanish — keep it well above 0.
        #expect(HLScoreRing.centreValueScaleFloor <= 0.667)
        #expect(HLScoreRing.centreValueScaleFloor > 0.4)
    }

    // MARK: - Deviation summary (Signale des Tages)

    @Test("deviation summary — only resolves for COINCIDENT_DEVIATION")
    func deviationSummaryGuard() {
        let notDeviation = Self.dto(metric: "READINESS", value: .init(score: 80, band: "green"))
        #expect(WellnessScorePresentation.deviationSummary(notDeviation) == nil)

        let value = DerivedMetricDTO.Value(
            fired: true,
            vitals: [
                .init(type: "RESTING_HEART_RATE", value: 72, center: 60, low: 54, high: 66, outside: true, direction: "above"),
                .init(type: "OXYGEN_SATURATION", value: 97, center: 97, low: 95, high: 99, outside: false, direction: "in")
            ],
            contributing: [
                .init(type: "RESTING_HEART_RATE", value: 72, center: 60, low: 54, high: 66, outside: true, direction: "above")
            ]
        )
        let summary = WellnessScorePresentation.deviationSummary(Self.dto(metric: "COINCIDENT_DEVIATION", value: value))
        #expect(summary?.fired == true)
        #expect(summary?.contributingCount == 1)
        #expect(summary?.checked == 2)
    }

    /// v0.14.8 Item-3 (b184 M4) — "Signals of the day" must hide the WHOLE section
    /// when there are no signals. A calm "all within range" envelope resolves to a
    /// non-nil summary with `fired == false` / zero contributing, so it must NOT
    /// satisfy the guard (no dangling heading). This delegates to the PRODUCTION
    /// predicate (`WellnessScorePresentation.showsSignalsSection`) both SwiftUI call
    /// sites use, so the test binds to the live gate and can't silently pass while
    /// the view drifts — the M4 divergence guard.
    private static func sectionShows(_ summary: WellnessScorePresentation.DeviationSummary?) -> Bool {
        WellnessScorePresentation.showsSignalsSection(summary)
    }

    @Test("signals section guard — calm/no-fired summary fails the show condition")
    func signalsSectionHideWhenEmpty() {
        // No signals fired today, nothing outside band → calm state.
        let calm = DerivedMetricDTO.Value(
            fired: false,
            vitals: [
                .init(type: "RESTING_HEART_RATE", value: 60, center: 60, low: 54, high: 66, outside: false, direction: "in")
            ],
            contributing: []
        )
        let calmSummary = WellnessScorePresentation.deviationSummary(Self.dto(metric: "COINCIDENT_DEVIATION", value: calm))
        // The summary still resolves (so the OLD guard would have shown it)…
        #expect(calmSummary != nil)
        // …but the NEW section guard is false → the whole section is omitted.
        #expect(Self.sectionShows(calmSummary) == false)

        // A fired summary with a contributing vital DOES satisfy the guard.
        let fired = DerivedMetricDTO.Value(
            fired: true,
            vitals: [
                .init(type: "RESTING_HEART_RATE", value: 80, center: 60, low: 54, high: 66, outside: true, direction: "above")
            ],
            contributing: [
                .init(type: "RESTING_HEART_RATE", value: 80, center: 60, low: 54, high: 66, outside: true, direction: "above")
            ]
        )
        let firedSummary = WellnessScorePresentation.deviationSummary(Self.dto(metric: "COINCIDENT_DEVIATION", value: fired))
        #expect(Self.sectionShows(firedSummary))
    }
}
