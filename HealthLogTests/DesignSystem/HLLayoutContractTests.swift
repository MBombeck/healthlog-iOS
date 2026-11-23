@testable import HealthLog
import SwiftUI
import Testing

/// Cards and rows take their measures from `HLLayout`. The suite measures the
/// laid-out building blocks, so a block that goes back to a number of its own
/// is caught even when the token itself is untouched.
@MainActor
@Suite("Layout roles carry cards and rows")
struct HLLayoutContractTests {
    @Test("the layout roles hold the agreed values")
    func roles() {
        #expect(HLLayout.pageMargin == 16)
        #expect(HLLayout.cardGap == 16)
        #expect(HLLayout.cardInset == 16)
        #expect(HLLayout.sectionGapBefore == 24)
        #expect(HLLayout.sectionGapAfter == 8)
        #expect(HLLayout.rowMinHeight == HLHitTarget.minimum)
        #expect(HLLayout.buttonHeight == 48)
        #expect(HLLayout.onboardingButtonHeight == 56)
        #expect(HLLayout.buttonGap == 8)
        #expect(HLLayout.iconButton == HLHitTarget.minimum)
        #expect(HLLayout.rowIcon == 26)
        #expect(HLLayout.chipHeight == 32)
        #expect(HLLayout.pageInsets.leading == HLLayout.pageMargin)
        #expect(HLLayout.pageInsets.trailing == HLLayout.pageMargin)
    }

    @Test("a card is its content plus the layout inset on every side", arguments: [HLCardStyle.standard, .outline])
    func cardInset(style: HLCardStyle) throws {
        let content = CGSize(width: 100, height: 40)
        let card = HLCard(style: style) {
            Color.clear.frame(width: content.width, height: content.height)
        }
        let fitted = try DesignContractMeasure.size(of: card, width: nil)
        #expect(fitted.width == content.width + 2 * HLLayout.cardInset)
        #expect(fitted.height == content.height + 2 * HLLayout.cardInset)

        let filling = try DesignContractMeasure.size(of: card)
        #expect(filling.width == 320, "a card takes the width it is offered")
        #expect(filling.height == fitted.height)
    }

    @Test("the former card styles draw as the two that remain")
    func cardStyleAliases() {
        #expect(HLCardStyle.elevated == .standard)
        #expect(HLCardStyle.ghost == .outline)
        #expect(HLCardSurface.content == .opaque, "content cards are opaque; glass belongs to bars and floating controls")
    }

    @Test("a one-line row that takes a tap is the layout's row height")
    func rowHeight() throws {
        let grid = try DesignContractMeasure.size(of: HLRowLayout(title: "Weight", indicator: .disclosure))
        #expect(grid.height == HLLayout.rowMinHeight)

        let settings = try DesignContractMeasure.size(of: HLSettingsRow(icon: "ruler", title: "Weight"))
        #expect(settings.height == HLLayout.rowMinHeight)

        let toggle = try DesignContractMeasure.size(
            of: HLSettingsToggleRow(title: "Weight", description: nil, isOn: .constant(true))
        )
        #expect(toggle.height == HLLayout.rowMinHeight)

        #expect(HLRowMetrics.minHeight == HLLayout.rowMinHeight)
        #expect(HLRowMetrics.gap == HLLayout.rowGap)
    }

    @Test("rows in a card and rows in a form stand on one grid")
    func rowGrid() {
        #expect(HLLayout.rowPitch == HLLayout.rowMinHeight + HLLayout.rowSpacing)
        let insets = HLFormRowMetrics.insets
        #expect(insets.top + HLLayout.rowMinHeight + insets.bottom == HLLayout.rowPitch)
        #expect(insets.leading == HLLayout.cardInset)
        #expect(insets.trailing == HLLayout.cardInset)

        #expect(HLFormRowMetrics.separator == .hidden, "no line stands between two rows")
    }

    @Test("a row card with n rows is n row pitches high, like a list section", arguments: [1, 2, 3])
    func rowCard(rows: Int) throws {
        #expect(HLLayout.rowCardInsetVertical == HLLayout.rowSpacing / 2)
        let titles = ["Weight", "Pulse", "Sleep"].prefix(rows)

        let card = try DesignContractMeasure.size(of: HLCard(layout: .rows) {
            ForEach(titles, id: \.self) { title in
                HLRowLayout(title: Text(verbatim: title), indicator: .disclosure)
            }
        })
        // A list section draws each row at the row pitch: the form row insets
        // around the row height, and the pitch as its minimum row height.
        let listSection = CGFloat(rows) * HLLayout.rowPitch
        #expect(card.height == listSection)
        #expect(card.height == CGFloat(rows) * 60)
    }

    @Test("under a title the row block is n row pitches high", arguments: [1, 2, 3])
    func titledRowBlock(rows: Int) throws {
        let titles = ["Weight", "Pulse", "Sleep"].prefix(rows)
        let empty = try DesignContractMeasure.size(of: HLCard("Overview", layout: .rows) {
            EmptyView()
        })
        let card = try DesignContractMeasure.size(of: HLCard("Overview", layout: .rows) {
            ForEach(titles, id: \.self) { title in
                HLRowLayout(title: Text(verbatim: title), indicator: .disclosure)
            }
        })
        // The card without rows keeps the two half spacings of its row block.
        let block = card.height - empty.height + 2 * HLLayout.rowCardInsetVertical
        #expect(block == CGFloat(rows) * HLLayout.rowPitch)
    }

    @Test("a card is free unless the call says rows, with and without a title")
    func cardLayoutIsTheCalls() throws {
        let text = Text(verbatim: "The server reports no sync health for this connection yet.")

        let plain = try DesignContractMeasure.size(of: HLCard { text })
        let plainFree = try DesignContractMeasure.size(of: HLCard(layout: .free) { text })
        let plainRows = try DesignContractMeasure.size(of: HLCard(layout: .rows) { text })
        #expect(plain.height == plainFree.height)
        #expect(plainFree.height - plainRows.height == 2 * (HLLayout.cardInset - HLLayout.rowCardInsetVertical))

        let titled = try DesignContractMeasure.size(of: HLCard("Overview") { text })
        let titledFree = try DesignContractMeasure.size(of: HLCard("Overview", layout: .free) { text })
        let titledRows = try DesignContractMeasure.size(of: HLCard("Overview", layout: .rows) { text })
        #expect(titled.height == titledFree.height, "a title made the card a row card")
        #expect(titledFree.height > titledRows.height)
    }

    @Test("under a title a free card ends its content as far from the lower edge as from its sides")
    func freeTitledCardRoom() throws {
        let block = DesignContractMeasure.marker.frame(height: 40)

        let free = try DesignContractMeasure.markerFrame(in: HLCard("Overview") { block })
        #expect(free.frame.minX == HLLayout.cardInset)
        #expect(free.size.width - free.frame.maxX == HLLayout.cardInset)
        #expect(free.size.height - free.frame.maxY == HLLayout.cardInset)
        #expect(free.size.height - free.frame.maxY == 16)

        // The row card keeps half a row spacing, and the same head above it.
        let rows = try DesignContractMeasure.markerFrame(in: HLCard("Overview", layout: .rows) { block })
        #expect(rows.size.height - rows.frame.maxY == HLLayout.rowCardInsetVertical)
        #expect(free.frame.minY - rows.frame.minY == HLSpace.md - HLLayout.rowCardInsetVertical)
    }

    @Test("a trailing element stands in the title row and drops under the title at the largest sizes")
    func cardHeaderTrailing() throws {
        let plain = HLCard("Overview") {
            HLRowLayout(title: "Weight", indicator: .disclosure)
        }
        let withPill = HLCard("Overview") {
            Color.clear.frame(width: 40, height: 10)
        } content: {
            HLRowLayout(title: "Weight", indicator: .disclosure)
        }
        let standard = try DesignContractMeasure.size(of: plain)
        let standardPill = try DesignContractMeasure.size(of: withPill)
        #expect(standardPill.height == standard.height, "a small trailing element shares the title's line")

        let large = try DesignContractMeasure.size(of: plain, typeSize: .accessibility3)
        let largePill = try DesignContractMeasure.size(of: withPill, typeSize: .accessibility3)
        #expect(largePill.height > large.height, "the trailing element kept squeezing the title")
    }

    @Test("a row grows with its text and never shrinks under the floor")
    func rowGrows() throws {
        let short = try DesignContractMeasure.size(of: HLRowLayout(title: "Weight"))
        let withSubtitle = try DesignContractMeasure.size(
            of: HLRowLayout(title: "Weight", subtitle: "Log a measurement")
        )
        let largest = try DesignContractMeasure.size(of: HLRowLayout(title: "Weight"), typeSize: .accessibility5)
        #expect(withSubtitle.height >= short.height)
        #expect(largest.height > short.height)
    }

    @Test("a row of facts is no control and keeps the height of its text")
    func statRowKeepsTextHeight() throws {
        let stat = try DesignContractMeasure.size(of: HLSettingsStatRow(label: Text(verbatim: "Build"), value: "302"))
        #expect(stat.height < HLLayout.rowMinHeight)
    }

    @Test("the row symbol has the layout's size and grows with the text up to its cap")
    func rowSymbol() throws {
        #expect(HLSettingsIconChip.baseSide == HLLayout.rowIcon)
        #expect(HLSettingsIconChip.side(forScaled: 10) == HLLayout.rowIcon)
        #expect(HLSettingsIconChip.side(forScaled: 40) == 40)
        #expect(HLSettingsIconChip.side(forScaled: 500) == HLSettingsIconChip.maxSide)

        let chip = HLSettingsIconChip(symbol: "ruler", tint: HLText.primary)
        let standard = try DesignContractMeasure.size(of: chip, width: nil)
        #expect(standard == CGSize(width: HLLayout.rowIcon, height: HLLayout.rowIcon))

        let largest = try DesignContractMeasure.size(of: chip, width: nil, typeSize: .accessibility5)
        #expect(largest.width > standard.width, "the symbol stayed small next to large text")
        #expect(largest.width <= HLSettingsIconChip.maxSide)
        #expect(largest.width == largest.height)
    }
}
