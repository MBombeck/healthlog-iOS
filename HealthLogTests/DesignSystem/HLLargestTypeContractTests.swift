@testable import HealthLog
import SwiftUI
import Testing

/// What three small building blocks do with a long word and with large text:
/// the word under a ring's value stays on one line, the glyph of a tile head
/// follows its title up to a cap, and a card label takes a second line
/// instead of being cut off.
@MainActor
@Suite("Long words and large text: ring caption, tile glyph, card label")
struct HLLargestTypeContractTests {
    /// The room a ring of about 96 pt leaves for the word in its centre.
    private static let ringCentre: CGFloat = 60

    private func caption(_ word: String, width: CGFloat?, typeSize: DynamicTypeSize = .large) throws -> CGSize {
        try DesignContractMeasure.size(
            of: HLScoreRingCaption(label: word, color: HLText.secondary),
            width: width,
            typeSize: typeSize
        )
    }

    @Test("the word under a ring's value stays on one line", arguments: [
        "Gesundheitsscore", "Herzfrequenzvariabilität"
    ])
    func ringCaptionKeepsOneLine(word: String) throws {
        let short = try caption("Score", width: Self.ringCentre)
        let long = try caption(word, width: Self.ringCentre)
        #expect(long.height <= short.height, "a second line would be taller than one")
    }

    @Test("the word under a ring's value keeps its size, like the ring", arguments: [
        DynamicTypeSize.xxxLarge, .accessibility1, .accessibility5
    ])
    func ringCaptionKeepsItsSize(typeSize: DynamicTypeSize) throws {
        let standard = try caption("Score", width: nil)
        #expect(try caption("Score", width: nil, typeSize: typeSize) == standard)
    }

    @Test("a long word under a ring's value at the largest text size is as tall as at the standard one")
    func ringCaptionLongWordAtLargestSize() throws {
        let standard = try caption("Gesundheitsscore", width: Self.ringCentre)
        let largest = try caption("Gesundheitsscore", width: Self.ringCentre, typeSize: .accessibility5)
        #expect(largest == standard)
    }

    private func glyph(_ typeSize: DynamicTypeSize) throws -> CGSize {
        try DesignContractMeasure.size(
            of: HLTileHeaderGlyph(systemName: "heart.fill"),
            width: nil,
            typeSize: typeSize
        )
    }

    @Test("the glyph of a tile head keeps its size at the standard text size")
    func tileGlyphAtStandardSize() throws {
        let fixed = try DesignContractMeasure.size(
            of: Image(systemName: "heart.fill").font(.hlIcon(HLTileHeaderGlyph.baseSize)),
            width: nil
        )
        #expect(try glyph(.large) == fixed)
    }

    @Test("the glyph of a tile head grows with the title and stops at its cap")
    func tileGlyphFollowsTheTitle() throws {
        let standard = try glyph(.large)
        let larger = try glyph(.xxLarge)
        let capped = try DesignContractMeasure.size(
            of: Image(systemName: "heart.fill").font(.hlIcon(HLTileHeaderGlyph.largestSize)),
            width: nil
        )
        #expect(larger.height > standard.height)
        #expect(try glyph(.accessibility1) == capped)
        #expect(try glyph(.accessibility5) == capped)
    }

    private func cardLabel(_ word: String, width: CGFloat) throws -> CGSize {
        try DesignContractMeasure.size(of: HLCardLabel(verbatim: word).lineLimit(1), width: width)
    }

    @Test("a long word in a card label takes a second line, even under a line limit")
    func cardLabelKeepsItsWord() throws {
        let short = try cardLabel("Puls", width: 120)
        let long = try cardLabel("Herzfrequenzvariabilität", width: 120)
        let wide = try cardLabel("Herzfrequenzvariabilität", width: 360)
        #expect(long.height > short.height)
        #expect(wide.height == short.height, "with room for the word the label stays one line high")
    }
}
