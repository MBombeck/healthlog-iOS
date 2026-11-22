@testable import HealthLog
import SwiftUI
import Testing

/// The name under a score ring never breaks inside a word: one word stays on
/// one line and shrinks, several words wrap at a space.
@Suite("Score ring tile label")
struct ScoreRingTileLabelTests {
    @Test("a single word keeps one line", arguments: ["Gesundheitsscore", "Tagesform", "Schlaf-Score", "Gezondheidsscore"])
    func singleWord(title: String) {
        #expect(ScoreRingTileLabel.lineLimit(for: title) == 1)
    }

    @Test("several words may wrap at a space", arguments: ["Health score", "Cardio Fitness", "Sleep score"])
    func severalWords(title: String) {
        #expect(ScoreRingTileLabel.lineLimit(for: title) == 2)
    }

    @Test("a single word may shrink further than before rather than break")
    func shrinksBeforeBreaking() {
        #expect(ScoreRingTileLabel.minimumScale < 0.85)
        #expect(ScoreRingTileLabel.minimumScale >= 0.7)
    }
}

/// A name under a score ring shrinks only at the accessibility sizes, so a
/// row never shows one name smaller than its neighbours at the usual sizes.
@Suite("Score ring tile label shrink")
struct ScoreRingTileLabelShrinkTests {
    @Test("no shrink below the accessibility sizes", arguments: [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge])
    func noShrink(size: DynamicTypeSize) {
        #expect(ScoreRingTileLabel.minimumScale(at: size) == 1)
    }

    @Test("a single word may shrink at the accessibility sizes", arguments: [DynamicTypeSize.accessibility1, .accessibility5])
    func shrinkAtAX(size: DynamicTypeSize) {
        #expect(ScoreRingTileLabel.minimumScale(at: size) == ScoreRingTileLabel.minimumScale)
    }
}
