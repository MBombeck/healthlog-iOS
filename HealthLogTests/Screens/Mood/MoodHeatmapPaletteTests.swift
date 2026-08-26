import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — pure locks for the mood-heatmap bucketer + the 90-day
/// pre-roll gate (DESIGN-B §1.2 / §1.5). No SwiftUI render pass.
@Suite("Mood heatmap palette + gate")
struct MoodHeatmapPaletteTests {
    @Test("daily-avg buckets snap to the nearest of 5 levels")
    func bucketMapping() {
        #expect(MoodHeatmapPalette.bucket(forAvg: 1.0) == 1)
        #expect(MoodHeatmapPalette.bucket(forAvg: 1.4) == 1)
        #expect(MoodHeatmapPalette.bucket(forAvg: 1.5) == 2) // .rounded() → 2 (banker's: 1.5→2)
        #expect(MoodHeatmapPalette.bucket(forAvg: 2.4) == 2)
        #expect(MoodHeatmapPalette.bucket(forAvg: 3.0) == 3)
        #expect(MoodHeatmapPalette.bucket(forAvg: 4.5) == 5) // 4.5 → 5 (away-from-zero)
        #expect(MoodHeatmapPalette.bucket(forAvg: 5.0) == 5)
    }

    @Test("zero / negative average → nil (no-entry day)")
    func bucketEmpty() {
        #expect(MoodHeatmapPalette.bucket(forAvg: 0) == nil)
        #expect(MoodHeatmapPalette.bucket(forAvg: -1) == nil)
    }

    @Test("bucket clamps out-of-range averages")
    func bucketClamps() {
        #expect(MoodHeatmapPalette.bucket(forAvg: 6.0) == 5)
        #expect(MoodHeatmapPalette.bucket(forAvg: 0.4) == 1) // > 0, rounds to 0 → clamp to floor 1
    }

    @Test("14-day gate hides only on brand-new devices (B13)")
    func historyGate() {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 13 days ago → below the tiny pre-roll gate.
        let recent = [cal.date(byAdding: .day, value: -13, to: now) ?? now]
        #expect(MoodHeatmapSection.hasEnoughHistory(in: recent, now: now) == false)
        // 14 days ago → exactly at the gate, renders.
        let atGate = [cal.date(byAdding: .day, value: -14, to: now) ?? now]
        #expect(MoodHeatmapSection.hasEnoughHistory(in: atGate, now: now) == true)
        // Well past (formerly hidden under the 90-day gate) → renders.
        let old = [cal.date(byAdding: .day, value: -30, to: now) ?? now]
        #expect(MoodHeatmapSection.hasEnoughHistory(in: old, now: now) == true)
        // empty → fails.
        #expect(MoodHeatmapSection.hasEnoughHistory(in: [], now: now) == false)
    }
}
