// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// W-B180 — pure layout decisions behind the hypnogram timeline.
    ///
    /// RCA "alle Balken kleben rechts": summary-shaped sources (WHOOP) store
    /// one row per stage with `measuredAt = sleep end`, so the reconstructed
    /// segments all SHARE the wake instant as their end → rendered literally,
    /// every bar hugs the right edge. `isSummaryShaped` detects that shape so
    /// the screen falls back to an honest distribution band; real per-segment
    /// nights keep the true time axis.
    @Suite("SleepHypnogramLayout — W-B180")
    struct SleepHypnogramLayoutTests {
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

        @Test("sequential per-segment night is NOT summary-shaped")
        func sequentialNightIsPositional() {
            let segments = [
                segment(.core, startMin: 0, endMin: 90),
                segment(.deep, startMin: 90, endMin: 150),
                segment(.rem, startMin: 150, endMin: 200)
            ]
            #expect(SleepHypnogramLayout.isSummaryShaped(segments) == false)
        }

        @Test("WHOOP-shaped totals (all ends == wake instant) ARE summary-shaped")
        func whoopTotalsAreSummaryShaped() {
            // start = end − minutes, end identical for every stage — exactly
            // what the server reconstructs from `mapSleep` rows.
            let segments = [
                segment(.awake, startMin: 450, endMin: 480),
                segment(.core, startMin: 220, endMin: 480),
                segment(.rem, startMin: 390, endMin: 480),
                segment(.deep, startMin: 400, endMin: 480)
            ]
            #expect(SleepHypnogramLayout.isSummaryShaped(segments))
        }

        @Test("single segment is never summary-shaped")
        func singleSegmentIsPositional() {
            #expect(SleepHypnogramLayout.isSummaryShaped(
                [segment(.asleep, startMin: 0, endMin: 445)]
            ) == false)
        }

        @Test("positionedSegments drops IN_BED and clamps to the bed span")
        func positionedSegmentsClampAndFilter() {
            let night = session([
                segment(.inBed, startMin: 0, endMin: 480), // excluded (top lane)
                segment(.core, startMin: -30, endMin: 90), // clamped to 0
                segment(.deep, startMin: 400, endMin: 600), // clamped to 480
                segment(.rem, startMin: 500, endMin: 520) // fully outside → dropped
            ])
            let positioned = SleepHypnogramLayout.positionedSegments(for: night)
            #expect(positioned.map(\.stage) == [.core, .deep])
            #expect(positioned[0].start == night.start)
            #expect(positioned[1].end == night.end)
        }

        @Test("distribution orders deep→shallow and excludes IN_BED")
        func distributionOrderAndShares() {
            var night = session([])
            night = SleepSession(
                night: night.night,
                source: night.source,
                start: night.start,
                end: night.end,
                asleepMinutes: nil,
                inBedMinutes: nil,
                awakeMinutes: nil,
                awakenings: nil,
                stages: [.deep: 60, .core: 240, .rem: 90, .awake: 10, .inBed: 480],
                segments: []
            )
            let items = SleepHypnogramLayout.distribution(for: night)
            #expect(items.map(\.stage) == [.deep, .core, .rem, .awake])
            let total = items.reduce(CGFloat(0)) { $0 + $1.fraction }
            #expect(abs(total - 1) < 0.0001)
        }
    }
#endif
