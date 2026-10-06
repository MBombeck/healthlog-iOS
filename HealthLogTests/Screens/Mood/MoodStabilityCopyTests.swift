import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — lock that every stability band maps to a distinct,
/// non-empty label + sentence (DESIGN-B §3.3), and that only the low band
/// flags the gauge marker. #115 1.3 — the bands are the server's four.
@Suite("Mood stability copy + flag")
struct MoodStabilityCopyTests {
    private static let bands: [MoodStability.Band] = [
        .verySteady, .steady, .variable, .veryVariable, .unknown
    ]

    @Test("every band has a non-empty label + sentence")
    func bandCopyPresent() {
        for band in Self.bands {
            #expect(!MoodStabilitySection.bandLabel(for: band).isEmpty)
            #expect(!MoodStabilitySection.sentence(for: band).isEmpty)
        }
    }

    @Test("band labels + sentences are all distinct")
    func bandCopyDistinct() {
        let labels = Set(Self.bands.map { MoodStabilitySection.bandLabel(for: $0) })
        let sentences = Set(Self.bands.map { MoodStabilitySection.sentence(for: $0) })
        #expect(labels.count == Self.bands.count)
        #expect(sentences.count == Self.bands.count)
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
