import Foundation
@testable import HealthLog
import Testing

/// Build 7 / item 7.1 — locks the projection contract the dashboard tiles use
/// to surface the web-parity secondary stats: the 7-/30-day averages (from the
/// comprehensive digest) and the target band ("Zielband", from the personal-
/// targets endpoint). Pure resolver, so no SwiftUI host is needed.
@Suite("DashboardTileTargetResolver — averages + target band")
struct DashboardTileTargetResolverTests {
    private func digest(weightAvg7: Double?, weightAvg30: Double?) -> ComprehensiveDigest {
        ComprehensiveDigest(
            summaries: ["WEIGHT": MetricSummary(avg7: weightAvg7, avg30: weightAvg30)]
        )
    }

    private func weightTarget(
        min: Double = 71,
        max: Double = 74,
        inRange: Int = 23,
        logged: Int = 30,
        insufficient: Bool = false
    ) -> InsightsTargetsResponseDTO {
        let item = InsightsTargetsResponseDTO.TargetItem(
            type: "WEIGHT",
            label: "Gewicht",
            current: 72.4,
            average30: 72.8,
            trend: .down,
            unit: "kg",
            range: .init(min: min, max: max),
            classification: nil,
            source: "profile",
            daysInRange7d: 5,
            daysLogged7d: 7,
            daysInRange30d: inRange,
            daysLogged30d: logged,
            lastMetGoalAt: nil,
            streakDays: 3,
            insufficientData: insufficient,
            consistency7d: []
        )
        return InsightsTargetsResponseDTO(
            targets: [item],
            pageSummary: .init(targetsMetThisWeek: 1, totalTargets: 1, streakHighlight: nil),
            bpDiastolic: nil,
            profile: nil
        )
    }

    // MARK: - Averages

    @Test("averages pulls avg7/avg30 from the digest summary for the kind")
    func averagesFromDigest() {
        let result = DashboardTileTargetResolver.averages(
            for: .weight,
            digest: digest(weightAvg7: 72.4, weightAvg30: 72.8)
        )
        #expect(result?.avg7 == 72.4)
        #expect(result?.avg30 == 72.8)
    }

    @Test("averages is nil for the composite blood-pressure tile (systolic-only summary would mislead)")
    func averagesNilForBloodPressure() {
        // Even with a BLOOD_PRESSURE_SYS summary present, the compound tile omits
        // the sub-row.
        let bpDigest = ComprehensiveDigest(
            summaries: ["BLOOD_PRESSURE_SYS": MetricSummary(avg7: 124, avg30: 126)]
        )
        #expect(DashboardTileTargetResolver.averages(for: .bloodPressure, digest: bpDigest) == nil)
    }

    @Test("averages is nil when the digest carries no summary for the kind")
    func averagesNilWhenSummaryMissing() {
        #expect(DashboardTileTargetResolver.averages(for: .pulse, digest: digest(weightAvg7: 72, weightAvg30: 72)) == nil)
        #expect(DashboardTileTargetResolver.averages(for: .weight, digest: nil) == nil)
    }

    @Test("averages is nil when both windows are empty")
    func averagesNilWhenBothWindowsEmpty() {
        #expect(DashboardTileTargetResolver.averages(for: .weight, digest: digest(weightAvg7: nil, weightAvg30: nil)) == nil)
    }

    @Test("averages surfaces a single present window")
    func averagesSinglePresentWindow() {
        let result = DashboardTileTargetResolver.averages(for: .weight, digest: digest(weightAvg7: nil, weightAvg30: 72.8))
        #expect(result?.avg7 == nil)
        #expect(result?.avg30 == 72.8)
    }

    // MARK: - Target band

    @Test("targetBand builds a RangeBand with the server in-range percentage")
    func targetBandFromTargets() {
        let band = DashboardTileTargetResolver.targetBand(for: .weight, targets: weightTarget(), units: .standard)
        // 23 / 30 → 77 %.
        #expect(band?.pctInRange == 77)
        #expect(band?.unit == "kg")
        #expect(band?.lowerLabel == "71")
        #expect(band?.upperLabel == "74")
    }

    @Test("targetBand is nil when the window is insufficient")
    func targetBandNilWhenInsufficient() {
        #expect(DashboardTileTargetResolver.targetBand(for: .weight, targets: weightTarget(insufficient: true), units: .standard) == nil)
    }

    @Test("targetBand is nil when nothing logged in the window")
    func targetBandNilWhenNothingLogged() {
        #expect(DashboardTileTargetResolver.targetBand(for: .weight, targets: weightTarget(inRange: 0, logged: 0), units: .standard) == nil)
    }

    @Test("targetBand is nil for a kind the user has no target for")
    func targetBandNilForUnconfiguredKind() {
        #expect(DashboardTileTargetResolver.targetBand(for: .pulse, targets: weightTarget(), units: .standard) == nil)
        #expect(DashboardTileTargetResolver.targetBand(for: .weight, targets: nil, units: .standard) == nil)
    }

    @Test("targetBand is nil for the composite blood-pressure tile")
    func targetBandNilForBloodPressure() {
        // A WEIGHT-only targets payload has nothing for BP anyway, but the guard
        // is explicit so a future BP target row can't surface a systolic-only band.
        #expect(DashboardTileTargetResolver.targetBand(for: .bloodPressure, targets: weightTarget(), units: .standard) == nil)
    }

    // MARK: - #20 pulse vs resting pulse

    /// The server `PULSE` target row is the resting-pulse band (`label:
    /// "Resting pulse"`, computed from the resting series, HealthLog
    /// `vitals-builder.ts`), so it belongs to the resting tile only.
    private func restingPulseTarget() -> InsightsTargetsResponseDTO {
        let item = InsightsTargetsResponseDTO.TargetItem(
            type: "PULSE",
            label: "Resting pulse",
            current: 72,
            average30: 71,
            trend: .stable,
            unit: "bpm",
            range: .init(min: 61, max: 77),
            classification: nil,
            source: "CDC/NCHS 2011",
            daysInRange7d: 7,
            daysLogged7d: 7,
            daysInRange30d: 30,
            daysLogged30d: 30,
            lastMetGoalAt: nil,
            streakDays: 30,
            insufficientData: false,
            consistency7d: []
        )
        return InsightsTargetsResponseDTO(
            targets: [item],
            pageSummary: .init(targetsMetThisWeek: 1, totalTargets: 1, streakHighlight: nil),
            bpDiastolic: nil,
            profile: nil
        )
    }

    private var pulseAndRestingDigest: ComprehensiveDigest {
        ComprehensiveDigest(summaries: [
            "PULSE": MetricSummary(count: 400, avg7: 80, avg30: 81),
            "RESTING_HEART_RATE": MetricSummary(count: 30, avg7: 72, avg30: 71)
        ])
    }

    @Test("resting + raw: the resting tile carries the resting averages and the resting band")
    func restingTileCarriesRestingBand() {
        let averages = DashboardTileTargetResolver.averages(for: .restingHeartRate, digest: pulseAndRestingDigest)
        #expect(averages?.avg7 == 72)
        #expect(averages?.avg30 == 71)
        let band = DashboardTileTargetResolver.targetBand(
            for: .restingHeartRate,
            targets: restingPulseTarget(),
            units: .standard
        )
        #expect(band?.lowerLabel == "61")
        #expect(band?.upperLabel == "77")
        #expect(band?.pctInRange == 100)
    }

    @Test("raw pulse never carries the resting band (HealthLog#584), whatever the targets say")
    func rawPulseNeverCarriesRestingBand() {
        #expect(DashboardTileTargetResolver.targetBand(for: .pulse, targets: restingPulseTarget(), units: .standard) == nil)
        // Its averages stay raw heart rate, matching its raw headline.
        let averages = DashboardTileTargetResolver.averages(for: .pulse, digest: pulseAndRestingDigest)
        #expect(averages?.avg7 == 80)
        #expect(averages?.avg30 == 81)
    }

    @Test("raw only: the pulse tile shows raw averages and no band")
    func rawOnlyNoBand() {
        let rawOnly = ComprehensiveDigest(summaries: ["PULSE": MetricSummary(count: 400, avg7: 80, avg30: 81)])
        #expect(DashboardTileTargetResolver.averages(for: .pulse, digest: rawOnly)?.avg7 == 80)
        #expect(DashboardTileTargetResolver.averages(for: .restingHeartRate, digest: rawOnly) == nil)
        #expect(DashboardTileTargetResolver.targetBand(for: .pulse, targets: restingPulseTarget(), units: .standard) == nil)
    }

    @Test("no targets: neither pulse tile shows a band")
    func noTargetsNoBand() {
        #expect(DashboardTileTargetResolver.targetBand(for: .pulse, targets: nil, units: .standard) == nil)
        #expect(DashboardTileTargetResolver.targetBand(for: .restingHeartRate, targets: nil, units: .standard) == nil)
    }
}
