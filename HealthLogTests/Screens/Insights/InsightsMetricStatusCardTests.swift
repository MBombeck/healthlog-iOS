import Foundation
@testable import HealthLog
import Testing

/// v0.14.3 C4 — locks the ONE-canonical-card invariant. The per-metric Insights
/// page used to fork on `kind == .bloodPressure` (rich `BPStatusCard` vs thin
/// `InsightsPrimaryTile`); the operator flagged "Puls looks completely
/// different from Blutdruck" across multiple rounds. These tests assert:
///   1. EVERY `MetricKind` routes through the SAME `InsightsMetricStatusCard`
///      descriptor builder (no per-kind fork in the view body); and
///   2. the honest-only contract holds — a sparse / empty digest yields a
///      reduced (or fully suppressed) card, never an empty chip or a fake
///      "Im Zielbereich".
@Suite("Insights canonical metric status card")
struct InsightsMetricStatusCardTests {
    // MARK: - No fork: every kind builds a descriptor

    @Test("every MetricKind builds a descriptor (no kind == .bloodPressure fork)")
    func everyKindBuildsADescriptor() {
        for kind in MetricKind.allCases {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: kind,
                digest: nil,
                target: nil,
                latestValue: nil
            )
            // The descriptor must always carry the localized title + the metric's
            // identifier suffix, regardless of kind — the single code path runs
            // for BP, BMI, Puls, Gewicht, Ruhepuls and every other metric.
            #expect(descriptor.title == kind.displayName)
            #expect(descriptor.identifierSuffix == kind.rawValue)
        }
    }

    @Test("the screen body has no per-kind primary-card fork")
    func screenBodyHasNoFork() throws {
        let source = try Self.loadMetricScreenSource()
        let code = Self.codeBody(of: source)
        // The retired fork constructed two divergent cards. Neither may be
        // constructed in the screen body any longer.
        #expect(!code.contains("BPStatusCard("), "BPStatusCard must be retired (folded into the canonical card).")
        #expect(!code.contains("InsightsPrimaryTile("), "InsightsPrimaryTile must be retired.")
        // The ONE canonical card must be the construction site.
        #expect(
            code.contains("InsightsMetricStatusCard(descriptor:"),
            "The screen must render the canonical InsightsMetricStatusCard for every metric."
        )
    }

    // MARK: - Self-suppression (honest-only)

    @Test("empty digest + no target yields a fully suppressed card")
    func emptyYieldsNoCard() {
        for kind in [MetricKind.pulse, .weight, .restingHeartRate, .bloodPressure, .bmi] {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: kind,
                digest: nil,
                target: nil,
                latestValue: nil
            )
            #expect(!descriptor.hasAnyContent, "\(kind): a metric with no signal must render no card.")
            #expect(descriptor.chipLabel == nil, "\(kind): no signal must mean no chip (no empty chip).")
            #expect(descriptor.pctInTarget == nil, "\(kind): no signal must mean no fake In-Range bar.")
            #expect(descriptor.targetBandCaption == nil, "\(kind): no signal must mean no Zielband.")
        }
    }

    @Test("sparse generic metric (only a latest value) shows a reduced card, no chip")
    func sparseGenericReducedCard() {
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: nil,
            target: nil,
            latestValue: 64
        )
        #expect(descriptor.hasAnyContent, "A latest value should still paint a (reduced) card.")
        #expect(descriptor.headlineValue == "64", "The honest headline is the latest reading.")
        #expect(descriptor.chipLabel == nil, "No target → no classification chip (no empty chip).")
        #expect(descriptor.pctInTarget == nil, "No target → no In-Range bar.")
        #expect(descriptor.targetBandCaption == nil, "No target → no Zielband.")
    }

    @Test("generic metric with a target surfaces chip + Zielband + In-Range pct")
    func genericWithTargetFullCard() {
        let target = InsightsTargetsResponseDTO.TargetItem(
            type: "PULSE",
            label: "Pulse",
            current: 62,
            average30: 64,
            trend: .stable,
            unit: "bpm",
            range: .init(min: 50, max: 80),
            classification: .init(category: "Im Zielbereich", color: "green"),
            source: "pulse",
            daysInRange7d: 6,
            daysLogged7d: 7,
            daysInRange30d: 24,
            daysLogged30d: 30,
            lastMetGoalAt: nil,
            streakDays: 4,
            insufficientData: false,
            consistency7d: [.inBand, .inBand, .inBand]
        )
        let digest = ComprehensiveDigest(summaries: ["PULSE": MetricSummary(avg30: 64)])
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: digest,
            target: target,
            latestValue: 62
        )
        #expect(descriptor.headlineValue == "64", "30-day avg is the canonical headline.")
        #expect(descriptor.chipLabel == "Im Zielbereich", "The server classification category is the chip.")
        #expect(descriptor.chipTone == .success, "Latest in-band bucket → success tone.")
        #expect(descriptor.pctInTarget == 80, "24/30 days in range → 80%.")
        #expect(descriptor.targetBandCaption != nil, "A configured range surfaces a Zielband.")
        // b183 coherence — the non-BP share is the local 30-day day-count window.
        #expect(
            descriptor.inTargetWindowLabel == String(localized: "30d"),
            "Non-BP in-target rides the local 30-day window → '30 T' label."
        )
    }

    @Test("insufficient-data target suppresses the In-Range bar")
    func insufficientTargetSuppressesBar() {
        let target = InsightsTargetsResponseDTO.TargetItem(
            type: "PULSE",
            label: "Pulse",
            current: 62,
            average30: nil,
            trend: nil,
            unit: "bpm",
            range: .init(min: 50, max: 80),
            classification: nil,
            source: "pulse",
            daysInRange7d: 0,
            daysLogged7d: 0,
            daysInRange30d: 0,
            daysLogged30d: 0,
            lastMetGoalAt: nil,
            streakDays: 0,
            insufficientData: true,
            consistency7d: []
        )
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: nil,
            target: target,
            latestValue: 62
        )
        #expect(descriptor.pctInTarget == nil, "insufficientData → no In-Range bar.")
        // The configured band still surfaces (honest reference even before a window accrues).
        #expect(descriptor.targetBandCaption != nil)
    }

    // MARK: - D1 target-less Verlauf (v0.14.4)

    @Test("a non-targeted kind (activeEnergy) shows a target-less Verlauf, no band/chip")
    func nonTargetedKindShowsTrendWithoutBand() {
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .activeEnergy,
            digest: ComprehensiveDigest(summaries: ["ACTIVE_ENERGY": MetricSummary(avg30: 480)]),
            target: nil, // server emits no target row for active energy
            latestValue: 510,
            sparklineValues: [420, 455, 480, 505, 510]
        )
        #expect(descriptor.showsSparkline, "A non-targeted kind with ≥2 points must paint the Verlauf.")
        #expect(descriptor.sparklineValues?.count == 5)
        #expect(descriptor.chipLabel == nil, "No target → no classification chip (no fabricated band).")
        #expect(descriptor.pctInTarget == nil, "No target → no fake In-Range bar.")
        #expect(descriptor.targetBandCaption == nil, "No target → no Zielband.")
        #expect(descriptor.hasAnyContent, "The trend (plus headline) keeps the card visible.")
    }

    @Test("a targeted kind (weight) keeps its full card and does NOT add a redundant Verlauf")
    func targetedKindKeepsFullCardNoSparkline() {
        let target = InsightsTargetsResponseDTO.TargetItem(
            type: "WEIGHT",
            label: "Weight",
            current: 78,
            average30: 79,
            trend: .down,
            unit: "kg",
            range: .init(min: 70, max: 80),
            classification: .init(category: "Im Zielbereich", color: "green"),
            source: "weight",
            daysInRange7d: 7,
            daysLogged7d: 7,
            daysInRange30d: 27,
            daysLogged30d: 30,
            lastMetGoalAt: nil,
            streakDays: 9,
            insufficientData: false,
            consistency7d: [.inBand]
        )
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .weight,
            digest: ComprehensiveDigest(summaries: ["WEIGHT": MetricSummary(avg30: 79)]),
            target: target,
            latestValue: 78,
            sparklineValues: [82, 81, 80, 79, 78]
        )
        #expect(descriptor.pctInTarget == 90, "Targeted kind keeps its In-Range bar (27/30 = 90%).")
        #expect(descriptor.targetBandCaption != nil, "Targeted kind keeps its Zielband.")
        #expect(descriptor.chipLabel != nil, "Targeted kind keeps its classification chip.")
        #expect(!descriptor.showsSparkline, "A targeted kind must not double up a redundant Verlauf.")
        #expect(descriptor.sparklineValues == nil, "The trend is suppressed when the In-Range bar is present.")
    }

    @Test("BMI carries the target-less Verlauf alongside its WHO band")
    func bmiCarriesTrendWithBand() {
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: ComprehensiveDigest(bmi: 24.2, bmiClassification: .normal),
            target: nil,
            latestValue: 24.2,
            sparklineValues: [25.1, 24.8, 24.5, 24.2]
        )
        #expect(descriptor.showsSparkline, "BMI has no In-Range bar, so it shows the Verlauf.")
        #expect(descriptor.targetBandCaption != nil, "BMI keeps its honest WHO band caption.")
        #expect(descriptor.pctInTarget == nil, "BMI never gets an In-Range bar (no day-share target).")
    }

    @Test("fewer than two points suppresses the Verlauf")
    func singlePointSuppressesTrend() {
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .activeEnergy,
            digest: nil,
            target: nil,
            latestValue: 510,
            sparklineValues: [510]
        )
        #expect(!descriptor.showsSparkline, "A single point is not a trend — suppress the sparkline.")
    }

    // MARK: - BP path

    @Test("blood pressure carries the ESH guideline + sys/dia headline + classification")
    func bloodPressureDescriptor() {
        let digest = ComprehensiveDigest(
            summaries: [
                "BLOOD_PRESSURE_SYS": MetricSummary(avg30: 128),
                "BLOOD_PRESSURE_DIA": MetricSummary(avg30: 82)
            ],
            bpClassification: .highNormal,
            bpPctInTarget: 71,
            bpTargets: BPTargets(sysLow: 120, sysHigh: 129, diaLow: 70, diaHigh: 79)
        )
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: digest,
            target: nil,
            latestValue: nil
        )
        #expect(descriptor.guidelineCaption != nil, "BP shows the ESH guideline caption.")
        #expect(descriptor.headlineValue == "128/82", "BP headline is the sys/dia 30-day pair.")
        #expect(descriptor.chipLabel != nil, "BP shows its ESH classification chip.")
        #expect(descriptor.pctInTarget == 71, "BP uses the server bpPctInTarget verbatim.")
        #expect(descriptor.targetBandCaption != nil, "BP shows its ESH target band.")
        // b183 coherence — BP in-target is the server's TRAILING 90-day share,
        // so the bar must carry the "90 T" window label (not the 30-day one the
        // non-BP bars use).
        #expect(
            descriptor.inTargetWindowLabel == String(localized: "90d"),
            "BP in-target rides the server 90-day window → '90 T' label."
        )
    }

    // MARK: - 1.4.1 — the guideline caption cites its guideline

    @Test("BP and BMI classifications name the guideline they rest on and cite it")
    func classificationCaptionsCarryTheirSourcesTopic() {
        let bp = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: ComprehensiveDigest(bpClassification: .highNormal),
            target: nil,
            latestValue: nil
        )
        #expect(bp.sourcesTopic == .bloodPressureClassification, "The ESH caption opens the BP-classification sources.")

        // Apple 1.4.1 — BMI used to classify silently. It now names WHO 2000 in
        // the header the way BP has always named ESH, and that caption is the
        // way into the WHO references.
        let bmi = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: ComprehensiveDigest(bmi: 24.2, bmiClassification: .normal),
            target: nil,
            latestValue: nil
        )
        #expect(bmi.guidelineCaption != nil, "BMI names the WHO 2000 guideline its bands come from.")
        #expect(bmi.sourcesTopic == .bmi, "The WHO caption opens the BMI sources.")

        // Every other metric classifies from the user's own target row, not from
        // a guideline — so it names none and the caption stays absent.
        let pulse = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: nil,
            target: nil,
            latestValue: 62
        )
        #expect(pulse.guidelineCaption == nil, "A target-driven metric has no guideline to name.")
        #expect(pulse.sourcesTopic == nil, "…and therefore nothing for the caption to cite.")
    }

    @Test("the card still reads as one sentence before its controls")
    func summaryAccessibilityLabelComposesTheCardsSlots() throws {
        // The card contains rather than combines its children now (the guideline
        // caption is a control), so the one-utterance summary the combine used
        // to produce has to be stated explicitly — and it must carry the same
        // facts the card shows.
        let bp = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: ComprehensiveDigest(
                summaries: [
                    "BLOOD_PRESSURE_SYS": MetricSummary(avg30: 128),
                    "BLOOD_PRESSURE_DIA": MetricSummary(avg30: 82)
                ],
                bpClassification: .highNormal
            ),
            target: nil,
            latestValue: nil
        )
        let label = InsightsMetricStatusCard.accessibilityLabel(for: bp)
        let chip = try #require(bp.chipLabel)
        let guideline = try #require(bp.guidelineCaption)
        #expect(label.contains(bp.title), "The summary names the metric.")
        #expect(label.contains(chip), "The summary carries the classification chip.")
        #expect(label.contains("128/82"), "The summary carries the headline value.")
        #expect(label.contains(guideline), "The summary names the guideline the chip rests on.")
        // 1.0.3 (1.4.1, audit row 10) — the qualifier the card now draws under
        // the chip is part of the claim, so VoiceOver must hear it too. A
        // sighted reviewer sees "not a diagnosis"; a screen-reader user used to
        // get the diagnostic category with nothing attached.
        let caption = try #require(bp.chipCaption, "BP classifies into a named category, so it carries the qualifier.")
        #expect(label.contains(caption), "The summary carries the 'not a diagnosis' qualifier.")

        // Honest-only: a slot the card does not show contributes no clause. A
        // target-driven metric has no guideline, so the guideline text is absent
        // rather than an empty ". ." in the middle of the sentence.
        let pulse = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: nil,
            target: nil,
            latestValue: 62
        )
        let pulseLabel = InsightsMetricStatusCard.accessibilityLabel(for: pulse)
        #expect(pulse.guidelineCaption == nil, "Precondition: the pulse card names no guideline.")
        // …and a target-driven metric claims no diagnostic category either, so
        // it carries no qualifier for one — honest-only on this slot as well.
        #expect(pulse.chipCaption == nil, "A target-driven metric makes no category claim to qualify.")
        #expect(!pulseLabel.contains(String(localized: "insights.digest.bp.guideline.esh2023")))
        #expect(!pulseLabel.contains(". ."), "An absent slot leaves no empty clause behind.")
        #expect(pulseLabel.hasPrefix(pulse.title), "The summary still opens with the metric.")
    }

    // MARK: - BMI path (honest: WEIGHT summary must NOT be mislabeled)

    @Test("BMI uses the server BMI value, never the WEIGHT summary average")
    func bmiUsesBmiValueNotWeightSummary() {
        // The digest carries a WEIGHT summary (BMI's availabilitySummaryKey) with
        // a weight average of 78.5 — that must NEVER surface as the BMI headline.
        let digest = ComprehensiveDigest(
            summaries: ["WEIGHT": MetricSummary(avg30: 78.5)],
            bmi: 24.2,
            bmiClassification: .normal
        )
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: digest,
            target: nil,
            latestValue: nil
        )
        // Locale-agnostic: compare against the SAME formatter the card uses, so
        // the assertion holds whether the runner is en (24.2) or de (24,2).
        let expected = 24.2.formatted(.number.precision(.fractionLength(1)))
        let weightAvg = 78.5.formatted(.number.precision(.fractionLength(1)))
        #expect(descriptor.headlineValue == expected, "BMI headline is the BMI value, not the weight average.")
        #expect(descriptor.headlineValue != weightAvg, "The WEIGHT summary average must NOT be shown as a BMI mean.")
        #expect(descriptor.chipLabel != nil, "BMI shows its WHO classification chip.")
    }

    @Test("BMI with no server BMI value falls back to the latest BMI reading, not WEIGHT")
    func bmiFallsBackToLatest() {
        let digest = ComprehensiveDigest(summaries: ["WEIGHT": MetricSummary(avg30: 78.5)])
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: digest,
            target: nil,
            latestValue: 23.7
        )
        let expected = 23.7.formatted(.number.precision(.fractionLength(1)))
        #expect(descriptor.headlineValue == expected, "BMI falls back to the latest BMI reading.")
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Insights/
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
    }

    private static func loadMetricScreenSource() throws -> String {
        let dir = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Insights")
        // file_length split: the screen's source spans the screen file plus its
        // `+Sections.swift` sibling (pure code movement) — assert across both.
        return try String(
            contentsOf: dir.appendingPathComponent("InsightsMetricScreen.swift"),
            encoding: .utf8
        ) + String(
            contentsOf: dir.appendingPathComponent("InsightsMetricScreen+Sections.swift"),
            encoding: .utf8
        )
    }

    private static func codeBody(of source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
            }
            .joined(separator: "\n")
    }
}

/// **1.0.3 — App Review 1.4.1, audit row 10.** The classification chip is the
/// card's most diagnosis-shaped element: "Hypertension grade 2" and "Obesity
/// class III" are category names out of a guideline, computed here from the
/// user's own 30-day home average. The mitigation used to live one tap away in
/// the Sources sheet. These tests hold it on the card — and hold the top bands
/// out of the alarm tone.
///
/// A suite of its own rather than more cases in the one above, which already
/// sits at the lint ceiling for type body length.
@Suite("Insights metric status card — 1.4.1 classification qualifier")
struct InsightsMetricStatusCardClassificationQualifierTests {
    @Test("BP and BMI chips carry the 'not a diagnosis' qualifier on the card itself")
    func classificationChipsCarryTheNotADiagnosisCaption() {
        let expected = String(localized: "insights.metric.statusCard.notADiagnosis")
        let bp = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: ComprehensiveDigest(bpClassification: .hypertensionGrade2),
            target: nil,
            latestValue: nil
        )
        #expect(bp.chipLabel != nil, "Precondition: the BP card shows a category chip.")
        #expect(bp.chipCaption == expected, "The BP category names itself as a category, not a diagnosis.")

        let bmi = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: ComprehensiveDigest(bmi: 41.0, bmiClassification: .obeseGradeIII),
            target: nil,
            latestValue: nil
        )
        #expect(bmi.chipLabel != nil, "Precondition: the BMI card shows a WHO category chip.")
        #expect(bmi.chipCaption == expected, "The WHO category carries the same qualifier as BP's.")
    }

    @Test("no BP or BMI classification paints in the alarm tone (R20)")
    func noHomeReadingCategoryIsCritical() {
        // Ruling R20. The first pass moved only the top band out of `.critical`,
        // which left the scale reading backwards — grade 2 red above grade 3
        // amber. The alarm tone leaves the vocabulary instead: a red chip on a
        // 30-day average of the user's own home readings is the card at its most
        // diagnosis-shaped, and the severity signal is what carries that, not
        // the category name. Exhaustive over both enums, so a case added later
        // cannot quietly bring the alarm back.
        for classification in BPClassification.allCases {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: .bloodPressure,
                digest: ComprehensiveDigest(bpClassification: classification),
                target: nil,
                latestValue: nil
            )
            #expect(descriptor.chipTone != .critical, "BP \(classification) must not paint in the alarm tone.")
        }
        for classification in BMIClassification.allCases {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: .bmi,
                digest: ComprehensiveDigest(bmi: 24.2, bmiClassification: classification),
                target: nil,
                latestValue: nil
            )
            #expect(descriptor.chipTone != .critical, "BMI \(classification) must not paint in the alarm tone.")
        }
    }

    @Test("the hypertensive and obesity bands keep their category and their warning tone")
    func escalatedBandsStayNamedAndAmber() {
        // Nothing is hidden by R20: the cited categories still render, and
        // `.warning` still separates them from the bands that are not escalated.
        for classification in [
            BPClassification.hypertensionGrade1, .hypertensionGrade2, .hypertensionGrade3
        ] {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: .bloodPressure,
                digest: ComprehensiveDigest(bpClassification: classification),
                target: nil,
                latestValue: nil
            )
            #expect(descriptor.chipLabel != nil, "BP \(classification) keeps its cited category (ESH 2023).")
            #expect(descriptor.chipTone == .warning, "BP \(classification) stays distinguishable as escalated.")
        }
        for classification in [BMIClassification.obeseGradeI, .obeseGradeII, .obeseGradeIII] {
            let descriptor = InsightsMetricStatusDescriptor.build(
                kind: .bmi,
                digest: ComprehensiveDigest(bmi: 41.0, bmiClassification: classification),
                target: nil,
                latestValue: nil
            )
            #expect(descriptor.chipLabel != nil, "BMI \(classification) keeps its cited category (WHO 2000).")
            #expect(descriptor.chipTone == .warning, "BMI \(classification) stays distinguishable as escalated.")
        }
        // The lower bands are untouched by R20 — they were never `.critical`.
        let healthy = InsightsMetricStatusDescriptor.build(
            kind: .bmi,
            digest: ComprehensiveDigest(bmi: 22.0, bmiClassification: .normal),
            target: nil,
            latestValue: nil
        )
        #expect(healthy.chipTone == .success, "A normal-weight chip still reads as reassuring.")
    }
}
