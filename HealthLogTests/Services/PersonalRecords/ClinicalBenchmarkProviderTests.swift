import Foundation
@testable import HealthLog
import Testing

/// v0.5.5.7 RECONCILE-COMPARE — `LiveClinicalBenchmarkProvider`
/// contract tests.
///
/// #115 1.3 — the live provider no longer carries hard-coded population
/// figures; the band geometry + classification helpers stay pinned for a
/// future server-shipped benchmark. These are pure value
/// assertions — no I/O, no concurrency.
@Suite("LiveClinicalBenchmarkProvider — benchmark data contract")
struct ClinicalBenchmarkProviderTests {
    private let provider = LiveClinicalBenchmarkProvider()

    // MARK: - #115 1.3 — no hard-coded population bands

    @Test("#115 1.3 — the live provider invents no benchmark for any kind (the server publishes none)")
    func noHardCodedBenchmarks() {
        for kind in MetricKind.allCases {
            #expect(provider.benchmark(for: kind) == nil, "benchmark invented for \(kind)")
        }
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
}
