import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Pure-function helpers backing `MetricChartContent` — covered in isolation so
/// the chart UI doesn't have to be instantiated to verify domain math.
@Suite("MetricChartContent helpers")
struct MetricChartContentHelpersTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("personalBaseline returns nil for fewer than 5 readings")
    func belowMinimumSampleSize() {
        let pts = (0 ..< 4).map { Self.point(idx: $0, value: 70.0) }
        #expect(personalBaseline(pts) == nil)
    }

    @Test("personalBaseline equals the median value for odd counts")
    func medianOfOddCounts() {
        // Values 70, 71, 72, 73, 74 → median = 72
        let pts = (0 ..< 5).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        #expect(personalBaseline(pts) == 72.0)
    }

    @Test("personalBaseline averages the two middle values for even counts")
    func medianOfEvenCounts() {
        // Values 70, 71, 72, 73, 74, 75 → median = (72 + 73) / 2 = 72.5
        let pts = (0 ..< 6).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        #expect(personalBaseline(pts) == 72.5)
    }

    @Test("personalBaseline only uses the most recent 90 readings")
    func windowedToLast90() {
        // 95 readings: ascending 0..94. Last 90 are 5..94 → median of those = 49.5
        let pts = (0 ..< 95).map { Self.point(idx: $0, value: Double($0)) }
        let baseline = personalBaseline(pts)
        // 90 values from 5..94 (sorted) → middle two are 49 and 50 → 49.5
        #expect(baseline == 49.5)
    }

    @Test("personalBaseline tolerates unsorted input by sorting internally")
    func unsortedInput() {
        let pts = [
            Self.point(idx: 0, value: 73),
            Self.point(idx: 1, value: 70),
            Self.point(idx: 2, value: 74),
            Self.point(idx: 3, value: 71),
            Self.point(idx: 4, value: 72)
        ]
        #expect(personalBaseline(pts) == 72.0)
    }
}

/// C-10 (2026-05-16) smoke test for the new `emphasisTint:` parameter on
/// `MetricChartContent.marks(...)`. We cannot pixel-snapshot a `ChartContent`
/// builder in a Swift Testing host (Charts require a UI render context), so
/// the strongest available lock is "builds for every MetricKind with and
/// without an emphasis tint" — guarantees the optional parameter signature
/// stays consistent across every per-kind branch.
@Suite("MetricChartContent.marks emphasisTint plumbing")
struct MetricChartContentEmphasisTintTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("Every MetricKind builds with the default emphasisTint (nil)")
    func defaultPathBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            // Force the @ChartContentBuilder to run through every case.
            // The static call alone is sufficient — we only need the
            // compiler to enforce the closed-switch contract end-to-end.
            _ = MetricChartContent.marks(for: kind, points: pts)
        }
    }

    @Test("Every MetricKind builds with a non-nil emphasisTint override")
    func explicitTintBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: Color.orange
            )
        }
    }
}

/// Home dashboard tile charts suppress the per-metric clinical
/// threshold / target rules (the red + grey "ideal" lines). The flag defaults
/// to `true` so the Insights detail charts keep their thresholds; the
/// `HLTileMetricChart` path passes `includeThresholds: false`.
@Suite("MetricChartContent.marks includeThresholds plumbing (v0.14.1 §1)")
struct MetricChartContentThresholdSuppressionTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("Every MetricKind builds with thresholds suppressed (tile path)")
    func suppressedThresholdsBuildForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(for: kind, points: pts, includeThresholds: false)
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: HLColor.inkGraphite,
                includeThresholds: false
            )
        }
    }
}

/// v0.14.3 §A1/§A2 — Home dashboard tile charts render ONE calm,
/// uniform line: no per-measurement dots (`showsPoints: false`) and a fixed
/// `HLChartGrid.tileSeriesWidth` stroke that matches the medication-compliance
/// primitive's quiet graphite. The flags default to the Insights-detail
/// behaviour (`showsPoints: true`, `seriesLineWidth: nil`) so the detail
/// charts stay byte-identical; only the `HLTileMetricChart` path passes the
/// tile values.
@Suite("MetricChartContent.marks tile line-only plumbing (v0.14.3 §A1/§A2)")
struct MetricChartContentTileLineOnlyTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    /// Every MetricKind builds through the tile path (dots off + fixed width).
    @Test("Every MetricKind builds with showsPoints:false + a fixed line width")
    func tilePathBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: HLColor.inkGraphite,
                includeThresholds: false,
                showsPoints: false,
                seriesLineWidth: HLChartGrid.tileSeriesWidth
            )
        }
    }

    /// The unified tile stroke width token equals the EXACT weight
    /// the medication-compliance `HLSparkline` + the Insights detail chart use
    /// (`HLChartStyle.lineWidth`), so every Home tile reads identically to the
    /// compliance line the operator anchored on. (It briefly diverged to 2.1 in
    /// v0.14.6; the felt mismatch was actually the dark-mode tint, not the width.)
    @Test("tileSeriesWidth token matches the compliance/detail line weight")
    func tileSeriesWidthTokenIsCalm() {
        #expect(HLChartGrid.tileSeriesWidth == HLChartStyle.lineWidth)
        #expect(HLChartGrid.tileSeriesWidth == 2.0)
    }
}

/// The gradient `AreaMark` was dropped from every metric branch; every kind
/// must still build through the chart switch.
@Suite("MetricChartContent.marks AreaMark removal (C-2)")
struct MetricChartContentNoAreaMarkTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    /// Smoke-test that the `@ChartContentBuilder` switch still builds for
    /// every metric kind.
    @Test("Every MetricKind still builds after AreaMark removal")
    func allKindsStillBuild() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(for: kind, points: pts)
            _ = MetricChartContent.marks(for: kind, points: pts, emphasisTint: HLColor.inkGraphite)
        }
    }
}

/// The charts draw no hard-coded clinical constants: a fixed mg/dL rule on a
/// series the server may deliver in mmol/L shows a wrong medical boundary, and
/// the private chart content is not reachable from a test, so this one reads
/// the source.
@Suite("MetricChartContent Theme-2.0 single-accent collapse (T2-3)")
struct MetricChartContentSingleAccentTests {
    private static func sourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../HealthLogTests/Screens/
            .deletingLastPathComponent() // .../HealthLogTests/
            .deletingLastPathComponent() // .../<repo-root>/
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")
    }

    /// The charts no longer draw hard-coded clinical constants
    /// (BP 140/60, pulse 100/60, glucose 70/180 mg/dL on a series that may be
    /// in mmol/L, fever 37.5, SpO2 95). Any rule comes from
    /// `MetricChartContent.clinicalThresholds(for:)`, which has no server
    /// source yet and is empty. This locks that the constants stay gone.
    @Test("No metric draws a hard-coded clinical threshold rule")
    func noHardCodedThresholdRules() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)
        for value in ["value: 140,", "value: 100,", "value: 60,", "value: 70,", "value: 180,", "value: 37.5,", "value: 95,"] {
            #expect(!source.contains(value), "hard-coded clinical rule `\(value)` is back in MetricChartContent.swift")
        }
        for kind in [MetricKind.bloodPressure, .pulse, .glucose, .bodyTemperature, .spo2] {
            #expect(MetricChartContent.clinicalThresholds(for: kind).isEmpty)
        }
    }
}
