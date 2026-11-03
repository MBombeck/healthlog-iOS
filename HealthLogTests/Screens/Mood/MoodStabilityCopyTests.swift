import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — lock that every stability band maps to a distinct,
/// non-empty label (DESIGN-B §3.3), and that only the low band flags the gauge
/// marker. #115 1.3 — the bands are the server's four. 1.4 B2 — the sentence
/// per band is gone; the card's one line is the label plus the server window.
@Suite("Mood stability copy + flag")
struct MoodStabilityCopyTests {
    private static let bands: [MoodStability.Band] = [
        .verySteady, .steady, .variable, .veryVariable, .unknown
    ]

    @Test("every band has a non-empty label, and the caption carries it with the window")
    func bandCopyPresent() {
        for band in Self.bands {
            let label = MoodStabilitySection.bandLabel(for: band)
            #expect(!label.isEmpty)
            let caption = MoodStabilitySection.caption(for: MoodStability(score: 60, stdDev: 0.8, band: band, days: 30))
            #expect(caption.contains(label))
            #expect(caption.contains("30"))
        }
    }

    @Test("band labels are all distinct")
    func bandCopyDistinct() {
        let labels = Set(Self.bands.map { MoodStabilitySection.bandLabel(for: $0) })
        #expect(labels.count == Self.bands.count)
    }

    @Test("only the server's lowest band flags the marker")
    func flaggingThreshold() {
        #expect(MoodStability.Band.verySteady.isFlagged == false)
        #expect(MoodStability.Band.steady.isFlagged == false)
        #expect(MoodStability.Band.variable.isFlagged == false)
        #expect(MoodStability.Band.veryVariable.isFlagged == true)
        #expect(MoodStability.Band.unknown.isFlagged == false)
    }
}
