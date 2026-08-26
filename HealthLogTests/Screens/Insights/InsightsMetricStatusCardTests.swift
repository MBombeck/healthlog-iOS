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
