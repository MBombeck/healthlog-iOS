import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Tab header, section header and chip: what recurs at the top of a tab,
/// above a card and in a filter bar has one height each, whatever stands in
/// its trailing place.
@MainActor
@Suite("Headers and chips keep one height")
struct HLHeaderContractTests {
    // MARK: - Tab header

    @Test("a tab header is as high as an icon button, with and without actions")
    func tabHeaderHeight() throws {
        #expect(HLTabHeaderMetrics.titleLineHeight == HLLayout.iconButton)

        let plain = try DesignContractMeasure.size(of: HLTabHeader("More"), width: 390)
        let withActions = try DesignContractMeasure.size(
            of: HLTabHeader("More") {
                HLIconButton(systemImage: "plus", label: "Add entry", style: .bar) {}
                HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {}
            },
            width: 390
        )
        #expect(plain.height == HLTabHeaderMetrics.titleLineHeight)
        #expect(withActions.height == plain.height, "actions moved the title of a tab")
    }

    @Test("a line under the title adds to the header; it does not move the title line")
    func tabHeaderSubtitle() throws {
        let plain = try DesignContractMeasure.size(of: HLTabHeader("More"), width: 390)
        let withSubtitle = try DesignContractMeasure.size(of: HLTabHeader("More", subtitle: "Daily"), width: 390)
        #expect(withSubtitle.height > plain.height)
    }

    @Test("a title breaks between its words, never inside one")
    func tabHeaderTitleWords() throws {
        #expect(HLTabHeaderTitle.words(of: "Blood pressure") == ["Blood", "pressure"])
        #expect(HLTabHeaderTitle.words(of: "Medikamente") == ["Medikamente"])
        #expect(HLTabHeaderTitle.words(of: "  Mehr  ") == ["Mehr"])

        let wide = try DesignContractMeasure.size(of: HLTabHeader("Blood pressure"), width: 390)
        let narrow = try DesignContractMeasure.size(of: HLTabHeader("Blood pressure"), width: 170)
        #expect(wide.height == HLTabHeaderMetrics.titleLineHeight)
        #expect(narrow.height > wide.height + 20, "the second word did not move to its own line")
    }

    @Test("the title follows the language of the view it stands in")
    func tabHeaderTitleLanguage() {
        #expect(HLTabHeaderTitle.resolved("More", locale: Locale(identifier: "de")) == "Mehr")
        #expect(HLTabHeaderTitle.resolved("More", locale: Locale(identifier: "nl")) == "Meer")
        #expect(HLTabHeaderTitle.resolved("More", locale: Locale(identifier: "en")) == "More")
    }

    // MARK: - Section header

    @Test("a section header brings 24 pt above and 8 pt below in a page")
    func sectionHeaderRoom() {
        #expect(HLSectionHeaderMetrics.before == HLLayout.sectionGapBefore)
        #expect(HLSectionHeaderMetrics.after == HLLayout.sectionGapAfter)
        let page = HLContainerGap(before: HLLayout.cardGap, after: HLLayout.cardGap)
        #expect(HLSectionHeaderMetrics.topPadding(in: page) + HLLayout.cardGap == HLLayout.sectionGapBefore)
        #expect(HLSectionHeaderMetrics.bottomPadding(in: page) + HLLayout.cardGap == HLLayout.sectionGapAfter)
    }

    @Test("a section header that hears nothing from its container brings its full room")
    func sectionHeaderWithoutContainer() throws {
        #expect(HLSectionHeaderMetrics.topPadding(in: .none) == HLLayout.sectionGapBefore)
        #expect(HLSectionHeaderMetrics.bottomPadding(in: .none) == HLLayout.sectionGapAfter)

        let header = HLSectionHeader("Medications")
        let alone = try DesignContractMeasure.size(of: header)
        let inPage = try DesignContractMeasure.size(of: header.hlContainerGap(HLLayout.cardGap))
        // In a page the stack's two gaps stand in for most of the room.
        #expect(alone.height - inPage.height == 2 * HLLayout.cardGap)
        let text = alone.height - HLLayout.sectionGapBefore - HLLayout.sectionGapAfter
        #expect(text > 0)
    }

    @Test("header and card stand 24 and 8 pt apart, in a page and in a foreign stack", arguments: [true, false])
    func sectionHeaderDistances(inPage: Bool) throws {
        let block: CGFloat = 40
        let spacing: CGFloat = inPage ? HLLayout.cardGap : 0
        let textHeight = try DesignContractMeasure.size(of: HLSectionHeader("Medications")).height
            - HLLayout.sectionGapBefore - HLLayout.sectionGapAfter

        let stack = VStack(spacing: spacing) {
            Color.clear.frame(height: block)
            HLSectionHeader("Medications")
            Color.clear.frame(height: block)
        }
        let measured = try DesignContractMeasure.size(of: inPage ? AnyView(stack.hlContainerGap(spacing)) : AnyView(stack))
        let expected = 2 * block + HLLayout.sectionGapBefore + textHeight + HLLayout.sectionGapAfter
        #expect(abs(measured.height - expected) <= 0.5, "\(measured.height) pt, expected \(expected) pt")
    }

    @Test("in a list with the page margins the header adds 8 pt to the section gap and 8 pt below")
    func sectionHeaderInList() {
        let list = HLContainerGap(before: HLLayout.cardGap, after: 0)
        #expect(HLSectionHeaderMetrics.topPadding(in: list) == HLLayout.sectionGapBefore - HLLayout.cardGap)
        #expect(HLSectionHeaderMetrics.bottomPadding(in: list) == HLLayout.sectionGapAfter)
        #expect(HLSectionHeaderMetrics.topPadding(in: HLContainerGap(before: 40, after: 0)) == 0)
    }

    @Test("a link at the trailing edge does not change the height of a section header")
    func sectionHeaderHeight() throws {
        let plain = try DesignContractMeasure.size(of: HLSectionHeader("Medications"))
        let linked = try DesignContractMeasure.size(
            of: HLSectionHeader("Medications") {
                HLLinkButton(HLControlWord.edit.key) {}
            }
        )
        #expect(abs(linked.height - plain.height) <= 1, "\(linked.height) pt with a link, \(plain.height) pt without")
        // Without a container the header brings its own room; the line of
        // text alone must stay lower than the link's tap target.
        let line = plain.height - HLSectionHeaderMetrics.before - HLSectionHeaderMetrics.after
        #expect(line < HLHitTarget.minimum, "\(line) pt for the line of text")
    }

    @Test("an area header outranks a group header")
    func sectionHeaderRanks() throws {
        let area = try DesignContractMeasure.size(of: HLSectionHeader("Medications", rank: .area))
        let group = try DesignContractMeasure.size(of: HLSectionHeader("Medications", rank: .group))
        #expect(area.height > group.height)
    }

    // MARK: - Chip

    @Test("a chip is 32 pt high and takes a tap on 44 pt")
    func chipMeasures() throws {
        #expect(HLChip.visibleHeight == HLLayout.chipHeight)
        #expect(HLChip.hitHeight == HLHitTarget.minimum)
        #expect(HLChip.hitOutset == (HLHitTarget.minimum - HLLayout.chipHeight) / 2)

        let idle = try DesignContractMeasure.size(of: HLChip("Week", isSelected: false) {}, width: nil)
        let chosen = try DesignContractMeasure.size(of: HLChip("Week", isSelected: true) {}, width: nil)
        #expect(idle.height == HLChip.visibleHeight)
        #expect(chosen == idle, "choosing a chip changed its size")

        let short = try DesignContractMeasure.size(of: HLChip(verbatim: "A", isSelected: false) {}, width: nil)
        #expect(short.width == HLChip.hitHeight, "a short chip is narrower than a tap target")
        #expect(short.height == HLChip.visibleHeight)
    }

    @Test("the tap area of a chip grows above and below, not to the sides")
    func chipHitArea() {
        let chip = CGRect(x: 0, y: 0, width: 80, height: HLChip.visibleHeight)
        let area = HLChipHitShape(outset: HLChip.hitOutset).path(in: chip).boundingRect
        #expect(area.height == HLChip.hitHeight)
        #expect(area.minX == chip.minX && area.maxX == chip.maxX, "the tap area reaches into the next chip")
        #expect(area.midY == chip.midY)
        // Two lines of chips stand a flow layout's gap apart: their tap
        // areas may meet, a chip's capsule is never under the other's area.
        #expect(HLChip.hitOutset <= HLSpace.sm)
    }

    @Test("a long chip wraps at the accessibility sizes and shortens below them")
    func chipWraps() throws {
        let name = "Blood pressure in the morning before breakfast"
        let chip = HLChip(verbatim: name, isSelected: false) {}
        let standard = try DesignContractMeasure.size(of: chip, width: 200)
        #expect(standard.height == HLChip.visibleHeight)
        #expect(standard.width <= 200)

        let oneLine = try DesignContractMeasure.size(
            of: HLChip(verbatim: "A", isSelected: false) {},
            width: nil,
            typeSize: .accessibility3
        )
        let large = try DesignContractMeasure.size(of: chip, width: 200, typeSize: .accessibility3)
        #expect(large.height > oneLine.height * 1.5, "the long name did not take a second line")
        #expect(large.width <= 200)

        let inFlow = try DesignContractMeasure.size(
            of: HLFlowLayout {
                HLChip(verbatim: "A", isSelected: false) {}
                chip
            },
            width: 200,
            typeSize: .accessibility3
        )
        #expect(inFlow.height >= oneLine.height + HLSpace.sm + large.height, "the flow layout cut the wrapped chip")
    }

    @Test("a chip with a symbol is as high as one without")
    func chipWithSymbol() throws {
        let plain = try DesignContractMeasure.size(of: HLChip("Notes", isSelected: false) {}, width: nil)
        let withSymbol = try DesignContractMeasure.size(
            of: HLChip("Notes", systemImage: "note.text", isSelected: false) {},
            width: nil
        )
        #expect(withSymbol.height == plain.height)
        #expect(withSymbol.width > plain.width)
    }
}
