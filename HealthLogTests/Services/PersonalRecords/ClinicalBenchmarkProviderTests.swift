import Foundation
@testable import HealthLog
import Testing

/// v0.5.5.7 RECONCILE-COMPARE — `LiveClinicalBenchmarkProvider`
/// contract tests.
///
/// Locks the 8 benchmark figures the comparison band consumes
/// against the cited sources, plus the deterministic
/// classification + favorability semantics. These are pure value
/// assertions — no I/O, no concurrency.
@Suite("LiveClinicalBenchmarkProvider — benchmark data contract")
struct ClinicalBenchmarkProviderTests {
    private let provider = LiveClinicalBenchmarkProvider()

    // MARK: - Per-kind benchmark numbers

    @Test("restingHeartRate benchmark matches CDC NHANES / AHA reference")
    func restingHeartRateBenchmark() {
        let benchmark = provider.benchmark(for: .restingHeartRate)
        #expect(benchmark != nil)
        #expect(benchmark?.mean == 70)
        #expect(benchmark?.sigma == 12)
        #expect(benchmark?.clinicalFloor == 50)
        #expect(benchmark?.clinicalCeiling == 100)
        #expect(benchmark?.favorability == .lowerIsBetter)
    }

    @Test("bloodPressure benchmark targets 120 mmHg systolic per AHA 2017")
    func bloodPressureBenchmark() {
        let benchmark = provider.benchmark(for: .bloodPressure)
        #expect(benchmark != nil)
        #expect(benchmark?.mean == 120)
        #expect(benchmark?.sigma == 12)
        #expect(benchmark?.clinicalCeiling == 140)
        #expect(benchmark?.favorability == .centered)
    }

    @Test("bodyFat benchmark uses 25% rough adult average")
    func bodyFatBenchmark() {
        let benchmark = provider.benchmark(for: .bodyFat)
        #expect(benchmark?.mean == 25)
        #expect(benchmark?.sigma == 6)
        #expect(benchmark?.favorability == .lowerIsBetter)
    }

    @Test("spo2 benchmark anchors 95% as WHO clinical floor")
    func spo2Benchmark() {
        let benchmark = provider.benchmark(for: .spo2)
        #expect(benchmark?.mean == 97)
        #expect(benchmark?.sigma == 2)
        #expect(benchmark?.clinicalFloor == 95)
        #expect(benchmark?.favorability == .higherIsBetter)
    }

    @Test("bmi benchmark uses WHO healthy band 18.5 – 25")
    func bmiBenchmark() {
        let benchmark = provider.benchmark(for: .bmi)
        #expect(benchmark?.mean == 24)
        #expect(benchmark?.sigma == 4)
        #expect(benchmark?.clinicalFloor == 18.5)
        #expect(benchmark?.clinicalCeiling == 25)
        #expect(benchmark?.favorability == .centered)
    }

    @Test("steps benchmark uses 7500/day Tudor-Locke + CDC adult mean")
    func stepsBenchmark() {
        let benchmark = provider.benchmark(for: .steps)
        #expect(benchmark?.mean == 7500)
        #expect(benchmark?.sigma == 3000)
        #expect(benchmark?.favorability == .higherIsBetter)
    }

    @Test("sleep benchmark uses NSF 7-9h adult target with 7h mean")
    func sleepBenchmark() {
        let benchmark = provider.benchmark(for: .sleep)
        #expect(benchmark?.mean == 7)
        #expect(benchmark?.sigma == 1)
        #expect(benchmark?.clinicalFloor == 6)
        #expect(benchmark?.clinicalCeiling == 9)
        #expect(benchmark?.favorability == .higherIsBetter)
    }

    // MARK: - Intentional gaps

    @Test("weight has no single-value benchmark (height/age/gender split required)")
    func weightHasNoBenchmark() {
        #expect(provider.benchmark(for: .weight) == nil)
    }

    @Test("hrv has no single-value benchmark (age cohort variance too high)")
    func hrvHasNoBenchmark() {
        #expect(provider.benchmark(for: .hrv) == nil)
    }

    @Test("vo2Max has no single-value benchmark (Cooper requires age + gender)")
    func vo2MaxHasNoBenchmark() {
        #expect(provider.benchmark(for: .vo2Max) == nil)
    }

    @Test("glucose has no single-value benchmark (fasting vs random ambiguity)")
    func glucoseHasNoBenchmark() {
        #expect(provider.benchmark(for: .glucose) == nil)
    }

    @Test("walking-* kinds have no benchmark (height-load-bearing)")
    func walkingKindsHaveNoBenchmark() {
        #expect(provider.benchmark(for: .walkingSpeed) == nil)
        #expect(provider.benchmark(for: .walkingAsymmetry) == nil)
        #expect(provider.benchmark(for: .walkingStepLength) == nil)
    }

    // MARK: - Band geometry helpers

    @Test("bandLow clamps to zero when mean - sigma would underflow")
    func bandLowClampsToZero() {
        let bench = ClinicalBenchmark(
            mean: 5,
            sigma: 10,
            favorability: .centered,
            sourceLabel: "test"
        )
        #expect(bench.bandLow == 0)
        #expect(bench.bandHigh == 15)
    }

    @Test("classify(_:) returns insideBand for value at mean")
    func classifyMeanIsInside() {
        let bench = ClinicalBenchmark(mean: 100, sigma: 10, favorability: .centered, sourceLabel: "test")
        #expect(bench.classify(100) == .insideBand)
        #expect(bench.classify(91) == .insideBand)
        #expect(bench.classify(109) == .insideBand)
    }

    @Test("classify(_:) returns belowBand for value below bandLow")
    func classifyBelowBand() {
        let bench = ClinicalBenchmark(mean: 100, sigma: 10, favorability: .centered, sourceLabel: "test")
        #expect(bench.classify(89) == .belowBand)
        #expect(bench.classify(0) == .belowBand)
    }

    @Test("classify(_:) returns aboveBand for value above bandHigh")
    func classifyAboveBand() {
        let bench = ClinicalBenchmark(mean: 100, sigma: 10, favorability: .centered, sourceLabel: "test")
        #expect(bench.classify(111) == .aboveBand)
        #expect(bench.classify(500) == .aboveBand)
    }

    // MARK: - Source-label coverage

    @Test("every populated benchmark carries a non-empty source label")
    func benchmarksAlwaysCarrySource() {
        let kindsWithBenchmark: [MetricKind] = [
            .restingHeartRate,
            .bloodPressure,
            .bodyFat,
            .spo2,
            .bmi,
            .steps,
            .sleep
        ]
        for kind in kindsWithBenchmark {
            let benchmark = provider.benchmark(for: kind)
            #expect(benchmark != nil)
            #expect(benchmark?.sourceLabel.isEmpty == false)
        }
    }
}
