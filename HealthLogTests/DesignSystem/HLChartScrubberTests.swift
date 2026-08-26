import Foundation
@testable import HealthLog
import Testing

/// v0.11 — the canonical scrubber's snap contract + the unified range-picker
/// option conformances. The scrubber is the ONE primitive every time-series
/// chart now uses to read a value, so its nearest-point lookup is the
/// load-bearing logic worth pinning.
@Suite("HLChartScrubber — nearest-point snap")
struct HLChartScrubberTests {
    private struct P {
        let at: Date
        let value: Double
    }

    private func points() -> [P] {
        let base = Date(timeIntervalSince1970: 0)
        return (0 ..< 5).map { i in
            P(at: base.addingTimeInterval(Double(i) * 86400), value: Double(i))
        }
    }

    @Test("Empty series snaps to nil")
    func emptySnapsNil() {
        let nearest = HLChartScrubber.nearest(to: .now, in: [P](), date: \.at)
        #expect(nearest == nil)
    }

    @Test("Exact-match date snaps to that point")
    func exactMatch() {
        let pts = points()
        let target = pts[2].at
        let nearest = HLChartScrubber.nearest(to: target, in: pts, date: \.at)
        #expect(nearest?.value == 2)
    }

    @Test("Between two points snaps to the closer one")
    func snapsToCloser() {
        let pts = points()
        // 0.4 days past index-1 → still closer to index-1 than index-2.
        let between = pts[1].at.addingTimeInterval(0.4 * 86400)
        let nearest = HLChartScrubber.nearest(to: between, in: pts, date: \.at)
        #expect(nearest?.value == 1)
        // 0.6 days past index-1 → now closer to index-2.
        let past = pts[1].at.addingTimeInterval(0.6 * 86400)
        #expect(HLChartScrubber.nearest(to: past, in: pts, date: \.at)?.value == 2)
    }

    @Test("Date before the series snaps to the first point")
    func beforeStart() {
        let pts = points()
        let early = pts[0].at.addingTimeInterval(-10 * 86400)
        #expect(HLChartScrubber.nearest(to: early, in: pts, date: \.at)?.value == 0)
    }

    @Test("Date after the series snaps to the last point")
    func afterEnd() {
        let pts = points()
        let late = pts[4].at.addingTimeInterval(10 * 86400)
        #expect(HLChartScrubber.nearest(to: late, in: pts, date: \.at)?.value == 4)
    }
}

/// Every chart's period control now shares one `HLRangeOption` contract, so
/// each option must expose a non-empty short label + a non-empty VoiceOver
/// label. A blank either way regresses the segmented-control a11y.
@Suite("HLRangeOption — unified range-picker options")
struct HLRangeOptionTests {
    @Test("ChartDetailStore.Range labels are populated")
    func chartDetailLabels() {
        for option in ChartDetailStore.Range.allCases {
            #expect(!option.label.isEmpty)
            #expect(!option.rangeAccessibilityLabel.isEmpty)
        }
    }

    @Test("TrendsOverlayStore.Range labels are populated")
    func trendsLabels() {
        for option in TrendsOverlayStore.Range.allCases {
            #expect(!option.label.isEmpty)
            #expect(!option.rangeAccessibilityLabel.isEmpty)
        }
    }

    @Test("MoodPeriod labels are populated")
    func moodLabels() {
        for option in MoodPeriod.allCases {
            #expect(!option.label.isEmpty)
            #expect(!option.rangeAccessibilityLabel.isEmpty)
        }
    }
}
