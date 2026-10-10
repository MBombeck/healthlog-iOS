import Foundation
@testable import HealthLog
import Testing

/// #20 — the server `PULSE` target row is the RESTING-pulse band (`label:
/// "Resting pulse"`, HealthLog `src/lib/targets/vitals-builder.ts`). On the
/// Insights pages it may sit on the resting heart rate card, never next to the
/// raw pulse 30-day average (HealthLog#584: the resting band is never applied
/// to raw pulse).
@Suite("Insights status card — resting band follows the resting series")
struct PulseRestingBandRuleTests {
    @Test("#20 the raw pulse card never carries the resting-pulse band (HealthLog#584)")
    func rawPulseCardIgnoresRestingBand() {
        let target = InsightsTargetsResponseDTO.TargetItem(
            type: "PULSE",
            label: "Resting pulse",
            current: 72,
            average30: 71,
            trend: .stable,
            unit: "bpm",
            range: .init(min: 61, max: 77),
            classification: .init(category: "In range", color: "green"),
            source: "CDC/NCHS 2011",
            daysInRange7d: 7,
            daysLogged7d: 7,
            daysInRange30d: 30,
            daysLogged30d: 30,
            lastMetGoalAt: nil,
            streakDays: 30,
            insufficientData: false,
            consistency7d: [.inBand]
        )
        let digest = ComprehensiveDigest(summaries: [
            "PULSE": MetricSummary(count: 400, avg30: 81),
            "RESTING_HEART_RATE": MetricSummary(count: 30, avg30: 71)
        ])
        let pulse = InsightsMetricStatusDescriptor.build(
            kind: .pulse,
            digest: digest,
            target: target,
            latestValue: 84,
            sparklineValues: [78, 84, 80]
        )
        #expect(pulse.headlineValue == "81", "The raw pulse card shows the raw 30-day average.")
        #expect(pulse.pctInTarget == nil, "No resting In-Range bar next to raw heart rate.")
        #expect(pulse.targetBandCaption == nil, "No resting target next to raw heart rate.")
        #expect(pulse.chipLabel == nil, "No resting classification next to raw heart rate.")
        #expect(pulse.showsSparkline, "Without a band the card keeps its target-less Verlauf.")
        let resting = InsightsMetricStatusDescriptor.build(
            kind: .restingHeartRate,
            digest: digest,
            target: target,
            latestValue: 72
        )
        #expect(resting.headlineValue == "71", "The resting card shows the resting 30-day average…")
        #expect(resting.pctInTarget == 100, "…next to the resting band it was judged against.")
        #expect(resting.targetBandCaption != nil)
    }

    @Test("#20 each kind's status card reads the target row whose band describes its series")
    func statusCardTargetTypes() {
        #expect(MetricChartMath.bandTargetType(for: .pulse) == nil)
        #expect(MetricChartMath.bandTargetType(for: .restingHeartRate) == "PULSE")
        #expect(MetricChartMath.bandTargetType(for: .weight) == "WEIGHT")
        #expect(MetricChartMath.bandTargetType(for: .sleep) == "SLEEP_DURATION")
    }
}
