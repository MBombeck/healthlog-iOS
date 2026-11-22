@testable import HealthLog
import SwiftUI
import Testing
import UIKit

extension E2BuildingBlockTests {
    @Test("an identifier may break after its separators and nowhere a hyphen would go")
    func identifierBreaks() {
        let mark = String(HLIdentifierText.breakMark)
        #expect(HLIdentifierText.breakable("uitest.hermetic.local") == "uitest.\(mark)hermetic.\(mark)local")
        #expect(HLIdentifierText.breakable("hlk_sweep_token") == "hlk_\(mark)sweep_\(mark)token")
        #expect(HLIdentifierText.breakable("https://a.b/mcp/") == "https:\(mark)/\(mark)/\(mark)a.\(mark)b/\(mark)mcp/")
        #expect(HLIdentifierText.breakable("plainword") == "plainword")
        #expect(HLIdentifierText.breakable("").isEmpty)
    }

    @Test("a copy carries the identifier exactly, without the break marks")
    func identifierCopiesClean() {
        for identifier in ["https://uitest.hermetic.local/mcp", "hlk_sweep_example_token", "console.anthropic.com"] {
            #expect(HLIdentifierText.copied(HLIdentifierText.breakable(identifier)) == identifier)
        }
    }

    @Test("the paragraph style of an identifier never hyphenates")
    func identifierNeverHyphenates() {
        let style = HLIdentifierText.paragraphStyle(alignment: .natural)
        #expect(style.hyphenationFactor == 0)
        #expect(!style.usesDefaultHyphenation)
        #expect(style.lineBreakMode == .byWordWrapping)
        #expect(HLIdentifierText.paragraphStyle(alignment: .right).alignment == .right)
    }

    @Test("an identifier laid out in a narrow column breaks at its separators, not into syllables")
    func identifierLayout() {
        let text = NSAttributedString(
            string: HLIdentifierText.breakable("uitest.hermetic.local"),
            attributes: [
                .font: UIFont.preferredFont(
                    forTextStyle: .subheadline,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
                ),
                .paragraphStyle: HLIdentifierText.paragraphStyle(alignment: .natural)
            ]
        )
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines: [String] = []
        let full = text.string as NSString
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(HLIdentifierText.copied(full.substring(with: characters)))
        }
        #expect(lines.count > 1, "the narrow column needs more than one line")
        #expect(lines.joined() == "uitest.hermetic.local", "no character was added, lines: \(lines)")
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(".") }, "every line ends at a separator: \(lines)")
    }
}
