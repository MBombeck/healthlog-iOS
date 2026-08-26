// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Accessibility
    import Foundation
    @testable import HealthLog
    import Testing

    /// A11Y (audit-v0162 §5) — the measured-hypnogram VoiceOver descriptor.
    ///
    /// The chart carried ONE flat `.accessibilityLabel` before; the descriptor
    /// now exposes one discrete data point per stage segment so VoiceOver walks
    /// the night phase by phase. These tests lock the pure ordering/exclusion
    /// contract (locale-independent) + the descriptor's structural shape.
    @Suite("SleepHypnogramAX — descriptor builder")
    struct SleepHypnogramAXTests {
        private let base = Date(timeIntervalSince1970: 1_780_000_000)

        private func segment(
            _ stage: SleepStage,
            startMin: Double,
            endMin: Double
        ) -> SleepSegment {
            SleepSegment(
                stage: stage,
                start: base.addingTimeInterval(startMin * 60),
                end: base.addingTimeInterval(endMin * 60),
                minutes: Int(endMin - startMin)
            )
        }

        private func session(_ segments: [SleepSegment], spanMinutes: Double = 480) -> SleepSession {
            SleepSession(
                night: base,
                source: "TEST",
                start: base,
                end: base.addingTimeInterval(spanMinutes * 60),
                asleepMinutes: nil,
                inBedMinutes: nil,
                awakeMinutes: nil,
                awakenings: nil,
                stages: [:],
                segments: segments
            )
        }

        @Test("orderedSegments excludes IN_BED, clamps, and sorts by onset")
        func orderedSegmentsContract() {
            // Deliberately out of chronological order + an IN_BED lane + an
            // out-of-span segment that must be dropped.
            let night = session([
                segment(.deep, startMin: 400, endMin: 600), // clamped to 480
                segment(.inBed, startMin: 0, endMin: 480), // excluded (top lane)
                segment(.core, startMin: -30, endMin: 90), // clamped to 0
                segment(.rem, startMin: 500, endMin: 520) // fully outside → dropped
            ])
            let ordered = SleepHypnogramAX.orderedSegments(for: night)
            // IN_BED gone, out-of-span gone, remaining sorted by start.
            #expect(ordered.map(\.stage) == [.core, .deep])
            #expect(ordered[0].start == night.start) // clamped lower bound
            #expect(ordered[1].end == night.end) // clamped upper bound
            // Strictly increasing onsets.
            #expect(ordered[0].start < ordered[1].start)
        }

        @Test("descriptor emits one data point per ordered segment")
        func descriptorDataPointArity() {
            let night = session([
                segment(.core, startMin: 0, endMin: 90),
                segment(.deep, startMin: 90, endMin: 150),
                segment(.rem, startMin: 150, endMin: 200)
            ])
            let d = SleepHypnogramAX.descriptor(for: night)
            #expect(d.series.count == 1)
            #expect(d.series.first?.dataPoints.count == 3)
            // Discrete stages, not a continuous line.
            #expect(d.series.first?.isContinuous == false)
            #expect(d.title?.isEmpty == false)
            #expect(d.summary?.isEmpty == false)
        }

        @Test("descriptor axes speak real labels, never (empty)")
        func descriptorAxesSpeak() {
            let night = session([
                segment(.core, startMin: 0, endMin: 90),
                segment(.deep, startMin: 90, endMin: 150)
            ])
            let d = SleepHypnogramAX.descriptor(for: night)

            // X axis speaks a clock time for an in-range offset; NaN stays empty.
            if let x = d.xAxis as? AXNumericDataAxisDescriptor {
                #expect(!x.valueDescriptionProvider(0).isEmpty)
                #expect(x.valueDescriptionProvider(.nan).isEmpty)
            } else {
                Issue.record("x-axis should be a numeric axis descriptor")
            }

            // Y axis speaks a stage name for a valid depth rank; an out-of-range
            // rank collapses to empty rather than a bogus label.
            if let y = d.yAxis {
                #expect(!y.valueDescriptionProvider(5).isEmpty) // deep
                #expect(y.valueDescriptionProvider(99).isEmpty)
            } else {
                Issue.record("y-axis should be a numeric axis descriptor")
            }
        }

        @Test("empty night yields a well-formed, point-free descriptor")
        func descriptorEmptyNight() {
            let d = SleepHypnogramAX.descriptor(for: session([]))
            #expect(d.series.first?.dataPoints.isEmpty == true)
            #expect(d.summary?.isEmpty == false)
        }
    }
#endif
