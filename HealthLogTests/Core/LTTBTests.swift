import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Unit coverage for `LTTB` — the shape-preserving downsampler that caps the
/// plotted mark count on the chart-detail surface (v0.7.1 W-CHARTS-LTTB).
///
/// Pure value-type math, no SwiftUI involved → testable without a host app.
@Suite("LTTB")
struct LTTBTests {
    // MARK: - Fixtures

    /// A monotonically-increasing-x ramp of `n` points, `y == x` so shape
    /// reasoning is trivial.
    private static func ramp(_ n: Int) -> [LTTB.Point] {
        (0 ..< n).map { LTTB.Point(x: Double($0), y: Double($0)) }
    }

    /// A series with a single sharp spike in the middle — the canonical case
    /// where mean-bucketing loses the peak but LTTB should keep it.
    private static func spike(count: Int, spikeAt: Int, spikeHeight: Double) -> [LTTB.Point] {
        (0 ..< count).map { idx in
            LTTB.Point(x: Double(idx), y: idx == spikeAt ? spikeHeight : 0.0)
        }
    }

    // MARK: - No-op / identity gates

    @Test("No-op when point count is at or below the threshold")
    func noOpWhenWithinThreshold() {
        let pts = Self.ramp(100)
        #expect(LTTB.downsample(pts, threshold: 100) == pts)
        #expect(LTTB.downsample(pts, threshold: 200) == pts)
        #expect(LTTB.downsample(pts, threshold: 101) == pts)
    }

    @Test("No-op for thresholds below 3 (LTTB needs ≥ 2 endpoints + 1 bucket)")
    func noOpForTinyThreshold() {
        let pts = Self.ramp(1000)
        #expect(LTTB.downsample(pts, threshold: 0) == pts)
        #expect(LTTB.downsample(pts, threshold: 1) == pts)
        #expect(LTTB.downsample(pts, threshold: 2) == pts)
    }

    @Test("Empty + single-point inputs pass through unchanged")
    func degenerateInputs() {
        #expect(LTTB.downsample([], threshold: 500).isEmpty)
        let one = [LTTB.Point(x: 1, y: 1)]
        #expect(LTTB.downsample(one, threshold: 500) == one)
    }

    // MARK: - Threshold respected

    @Test("Output never exceeds the threshold")
    func thresholdRespected() {
        let pts = Self.ramp(10000)
        for threshold in [3, 10, 50, 250, 500, 999] {
            let out = LTTB.downsample(pts, threshold: threshold)
            #expect(out.count == threshold, "threshold \(threshold) → got \(out.count)")
        }
    }

    @Test("Downsampling actually reduces a large series")
    func reducesLargeSeries() {
        let pts = Self.ramp(5000)
        let out = LTTB.downsample(pts, threshold: 500)
        #expect(out.count == 500)
        #expect(out.count < pts.count)
    }

    // MARK: - Endpoints retained

    @Test("First and last points are retained verbatim")
    func endpointsRetained() {
        let pts = Self.ramp(3000)
        let out = LTTB.downsample(pts, threshold: 400)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    @Test("Endpoints retained even at the minimum threshold of 3")
    func endpointsRetainedAtMinThreshold() {
        let pts = Self.ramp(1000)
        let out = LTTB.downsample(pts, threshold: 3)
        #expect(out.count == 3)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    // MARK: - Monotonic x preserved

    @Test("Monotonic-ascending x is preserved in the output")
    func monotonicXPreserved() {
        let pts = Self.ramp(7777)
        let out = LTTB.downsample(pts, threshold: 600)
        for i in 1 ..< out.count {
            #expect(out[i - 1].x < out[i].x, "x out of order at \(i): \(out[i - 1].x) !< \(out[i].x)")
        }
    }

    @Test("Output is a subsequence of the input (LTTB never synthesises points)")
    func outputIsSubsequence() {
        let pts = Self.ramp(2000)
        let out = LTTB.downsample(pts, threshold: 300)
        let inputXs = Set(pts.map(\.x))
        for p in out {
            #expect(inputXs.contains(p.x), "synthesised point at x=\(p.x)")
        }
    }

    // MARK: - Shape preservation

    @Test("A sharp spike survives downsampling")
    func spikePreserved() {
        // 2001 points, a single spike of height 1000 at the centre. Mean
        // bucketing would dilute the spike; LTTB should keep the apex.
        let pts = Self.spike(count: 2001, spikeAt: 1000, spikeHeight: 1000)
        let out = LTTB.downsample(pts, threshold: 200)
        let maxY = out.map(\.y).max() ?? 0
        #expect(maxY == 1000, "spike apex lost — max y in output was \(maxY)")
    }

    @Test("selectedIndices returns ascending in-bounds indices")
    func selectedIndicesValid() {
        let pts = Self.ramp(4000)
        let idx = LTTB.selectedIndices(pts, threshold: 500)
        #expect(idx.count == 500)
        #expect(idx.first == 0)
        #expect(idx.last == pts.count - 1)
        for i in 1 ..< idx.count {
            #expect(idx[i - 1] < idx[i], "indices not strictly ascending at \(i)")
            #expect(idx[i] >= 0 && idx[i] < pts.count)
        }
    }

    @Test("selectedIndices returns full range when no downsampling applies")
    func selectedIndicesIdentity() {
        let pts = Self.ramp(50)
        #expect(LTTB.selectedIndices(pts, threshold: 500) == Array(0 ..< 50))
        #expect(LTTB.selectedIndices(pts, threshold: 2) == Array(0 ..< 50))
    }

    // MARK: - SeriesPoint domain mapping

    private static func seriesPoints(_ n: Int, withSecondary: Bool = false) -> [SeriesPoint] {
        let anchor = Date(timeIntervalSinceReferenceDate: 0)
        return (0 ..< n).map { idx in
            SeriesPoint(
                id: "sp-\(idx)",
                at: anchor.addingTimeInterval(TimeInterval(idx) * 3600),
                value: Double(idx),
                secondary: withSecondary ? Double(idx) + 0.5 : nil
            )
        }
    }

    @Test("downsampleSeries: passes short series through unchanged (default threshold)")
    func seriesPassThrough() {
        let pts = Self.seriesPoints(365)
        let out = LTTB.downsampleSeries(pts)
        #expect(out.count == pts.count)
        #expect(out.first?.id == "sp-0")
        #expect(out.last?.id == "sp-364")
    }

    @Test("downsampleSeries: caps a large series at the default plot threshold")
    func seriesCapped() {
        let pts = Self.seriesPoints(5000)
        let out = LTTB.downsampleSeries(pts)
        #expect(out.count == LTTB.seriesPlotThreshold)
        // Endpoints by identity, not just by value.
        #expect(out.first?.id == "sp-0")
        #expect(out.last?.id == "sp-4999")
    }

    @Test("downsampleSeries: preserves id / at / secondary of surviving points")
    func seriesPreservesIdentity() {
        let pts = Self.seriesPoints(3000, withSecondary: true)
        let out = LTTB.downsampleSeries(pts, threshold: 400)
        #expect(out.count == 400)
        // Every survivor must be the *exact* original SeriesPoint (id + at +
        // value + secondary), proving LTTB selected, never synthesised.
        let byId = Dictionary(uniqueKeysWithValues: pts.map { ($0.id, $0) })
        for survivor in out {
            let original = byId[survivor.id]
            #expect(original != nil, "survivor id \(survivor.id) not in input")
            #expect(survivor.at == original?.at)
            #expect(survivor.value == original?.value)
            #expect(survivor.secondary == original?.secondary)
        }
        // `at` stays monotonic ascending — load-bearing for the chart x-axis.
        for i in 1 ..< out.count {
            #expect(out[i - 1].at < out[i].at)
        }
    }

    @Test("downsampleSeries: explicit threshold honoured")
    func seriesExplicitThreshold() {
        let pts = Self.seriesPoints(2000)
        let out = LTTB.downsampleSeries(pts, threshold: 100)
        #expect(out.count == 100)
    }
}
