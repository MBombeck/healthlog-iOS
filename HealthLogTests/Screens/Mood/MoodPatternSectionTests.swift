import Foundation
@testable import HealthLog
import Testing

/// v0.10.0 W-Mood-A — lock that every pattern kind maps to a non-empty
/// category label and both strengths render copy (DESIGN-B §5.1/§5.6).
@Suite("Mood pattern card copy")
struct MoodPatternSectionTests {
    private static let kinds: [MoodPattern.Kind] = [
        .previousDay, .weekend, .bestWeekday, .tagPositive,
        .tagNegative, .notePresence, .laggedTag, .multiEntry
    ]

    @Test("every pattern kind has a non-empty category label")
    func categoryLabelsPresent() {
        for kind in Self.kinds {
            #expect(!MoodPatternSection.categoryLabel(kind).isEmpty)
        }
    }

    @Test("both strengths render distinct copy")
    func strengthCopy() {
        let strong = MoodPatternSection.strengthLabel(.strong)
        let moderate = MoodPatternSection.strengthLabel(.moderate)
        #expect(!strong.isEmpty)
        #expect(!moderate.isEmpty)
        #expect(strong != moderate)
    }

    /// D7 — the visible strength chip (replaces the unclear "•••" dot meter)
    /// renders distinct, non-empty short labels for both strengths.
    @Test("strength chip labels are distinct + non-empty")
    func strengthChipLabels() {
        let strong = MoodPatternSection.strengthChipLabel(.strong)
        let moderate = MoodPatternSection.strengthChipLabel(.moderate)
        #expect(!strong.isEmpty)
        #expect(!moderate.isEmpty)
        #expect(strong != moderate)
    }
}
