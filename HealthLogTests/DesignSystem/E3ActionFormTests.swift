import CoreGraphics
@testable import HealthLog
import SwiftUI
import Testing

/// The action forms of E3, held to their target forms: one quiet link in two
/// places, one way to load more, one choice row, one remove, one symbol
/// button with a loading and an inline size, one stepper, one composer, one
/// order for the bar of a pushed page, and the period choice above the chart.
/// Each family's cases stand in an extension of their own.
@MainActor
@Suite("E3 action forms")
struct E3ActionFormTests {}

// MARK: - Words without hyphenation

extension E3ActionFormTests {
    private func size(_ width: CGFloat, _ height: CGFloat = 20) -> CGSize {
        CGSize(width: width, height: height)
    }

    @Test("prose splits at whitespace, a run of spaces is one gap")
    func wordsSplit() {
        #expect(HLWholeWordText.words("Jetzt  synchronisieren\n") == ["Jetzt", "synchronisieren"])
        #expect(HLWholeWordText.words("").isEmpty)
    }

    @Test("a word that does not fit the rest of a line moves to the next one whole")
    func wordMovesWhole() {
        let frames = HLWordFlowLayout.frames(for: [size(60), size(70)], width: 100, space: 5)
        #expect(frames[0].origin == .zero)
        #expect(frames[1].minX == 0, "the second word starts a line of its own")
        #expect(frames[1].minY == 20)
        #expect(frames[1].width == 70, "the word keeps its width: it is not split")
    }

    @Test("words that fit share a line, one space apart")
    func wordsShareLine() {
        let frames = HLWordFlowLayout.frames(for: [size(40), size(50)], width: 100, space: 5)
        #expect(frames[1].minX == 45)
        #expect(frames[1].minY == 0)
    }

    @Test("a word wider than the line gets the line's width on a line of its own")
    func longWordShrinks() {
        let frames = HLWordFlowLayout.frames(for: [size(30), size(240), size(30)], width: 100, space: 5)
        #expect(frames[1].width == 100)
        #expect(frames[1].minY == 20)
        #expect(frames[2].minY == 40)
        #expect(HLWholeWordText.minimumScale == 0.5)
    }

    @Test("centred lines stand in the middle of the width")
    func centredLine() {
        let frames = HLWordFlowLayout.frames(for: [size(40)], width: 100, space: 5, alignment: .center)
        #expect(frames[0].minX == 30)
    }

    @Test("a tile action title shrinks a little on one line and wraps between words from AX on")
    func tileActionTitle() {
        #expect(HLTileAction.titleMinimumScale == 0.85)
        #expect(HLTileAction.wrapsTitle(at: .accessibility1))
        #expect(!HLTileAction.wrapsTitle(at: .xxxLarge))
    }

    @Test("a button title wraps between whole words at the accessibility sizes when its words are known")
    func buttonWholeWords() {
        #expect(HLButtonLabel.wrapsWholeWords(at: .accessibility3, words: "Jetzt synchronisieren"))
        #expect(!HLButtonLabel.wrapsWholeWords(at: .xxxLarge, words: "Jetzt synchronisieren"))
        #expect(!HLButtonLabel.wrapsWholeWords(at: .accessibility3, words: nil))
    }

    @Test("a catalog key gives its words; a key with arguments gives none")
    func localizedKeyWords() {
        let plain = HLLocalizedKey.string("Load more")
        #expect(plain?.isEmpty == false)
        let count = 3
        #expect(HLLocalizedKey.string("\(count) items") == nil)
        #expect(HLLocalizedKey.string(forKey: "e3.no.such.key") == "e3.no.such.key")
    }

    @Test("the wrapped button grows around its lines instead of cutting them")
    func wrappedButtonGrows() throws {
        let narrow = try DesignContractMeasure.size(
            of: HLButton(verbatim: "Jetzt synchronisieren", variant: .secondary) {},
            width: 220,
            typeSize: .accessibility5
        )
        let line = try DesignContractMeasure.size(
            of: HLButton(verbatim: "Jetzt", variant: .secondary) {},
            width: 220,
            typeSize: .accessibility5
        )
        #expect(narrow.height > line.height, "two lines, not one cut line: \(narrow.height) vs \(line.height)")
    }
}

// MARK: - Links and loading more

extension E3ActionFormTests {
    @Test("the quiet link stands centred under a card or leading inside one, 44 pt high")
    func linkPlaces() throws {
        #expect(HLLinkButton.frameAlignment(for: .center) == .center)
        #expect(HLLinkButton.frameAlignment(for: .leading) == .leading)
        #expect(HLLinkButton.textAlignment(for: .leading) == .leading)
        #expect(HLLinkButton.hitHeight == HLHitTarget.minimum)
        let leading = try DesignContractMeasure.size(
            of: HLLinkButton("Ask the coach", systemImage: "sparkles", alignment: .leading) {}
        )
        #expect(leading.height >= HLHitTarget.minimum)
        #expect(leading.width == 320, "the link takes the row, its words sit at the leading edge")
    }

    @Test("load more: a link on a page, the spinner while loading, nothing without more")
    func loadMoreShapes() {
        #expect(HLLoadMoreRow.shape(hasMore: false, isLoading: false, trigger: .link) == .hidden)
        #expect(HLLoadMoreRow.shape(hasMore: true, isLoading: false, trigger: .link) == .link)
        #expect(HLLoadMoreRow.shape(hasMore: true, isLoading: true, trigger: .link) == .progress(loadsOnAppear: false))
        #expect(HLLoadMoreRow.shape(hasMore: true, isLoading: false, trigger: .onAppear) == .progress(loadsOnAppear: true))
        #expect(HLLoadMoreRow.shape(hasMore: true, isLoading: true, trigger: .onAppear) == .progress(loadsOnAppear: false))
        #expect(HLLoadMoreRow.shape(hasMore: false, isLoading: true, trigger: .onAppear) == .hidden)
    }

    @Test("link and spinner of load more stand at the same height")
    func loadMoreKeepsHeight() throws {
        let link = try DesignContractMeasure.size(of: HLLoadMoreRow(hasMore: true, isLoading: false) {})
        let loading = try DesignContractMeasure.size(of: HLLoadMoreRow(hasMore: true, isLoading: true) {})
        #expect(link.height == loading.height, "\(link.height) vs \(loading.height)")
        #expect(HLLoadMoreRow.height == HLLinkButton.hitHeight)
    }

    @Test("a text link carries the external sign only when it leaves the app")
    func textLinkExternal() {
        #expect(HLTextLink.isExternal(URL(string: "https://open-meteo.com")))
        #expect(HLTextLink.isExternal(URL(string: "tel:112")))
        #expect(!HLTextLink.isExternal(URL(string: "healthlog://insights/pulse")))
        #expect(!HLTextLink.isExternal(nil))
        #expect(HLTextLink.externalSymbol == HLRowIndicator.externalSymbol)
        #expect(HLTextLink.hitOutset * 2 + 20 >= HLHitTarget.minimum, "a footnote line plus the outset is a full tap area")
    }

    @Test("one spinner size in content")
    func inlineProgress() {
        #expect(HLInlineProgress.controlSize == .small)
    }
}

// MARK: - Choice, remove, symbol buttons

extension E3ActionFormTests {
    @Test("single choice: check mark trailing on the chosen row only; multiple: circle leading")
    func choiceSigns() {
        #expect(HLChoiceRow.symbol(mode: .single, isSelected: true) == "checkmark")
        #expect(HLChoiceRow.symbol(mode: .single, isSelected: false) == nil)
        #expect(HLChoiceRow.symbol(mode: .multiple, isSelected: true) == "checkmark.circle.fill")
        #expect(HLChoiceRow.symbol(mode: .multiple, isSelected: false) == "circle")
        #expect(HLChoiceRow.edge(for: .single) == .trailing)
        #expect(HLChoiceRow.edge(for: .multiple) == .leading)
    }

    @Test("the mark of a choice keeps its side at every size")
    func choiceMarkKeepsSide() {
        #expect(HLChoiceRow.configuration.stacking == .never)
        typealias Adaptive = HLAdaptiveSegmentedPicker<String, EmptyView>
        #expect(Adaptive.menuMinimumScale == 0.6)
        #expect(Adaptive.selectedLabel("last", labels: ["This week", "Last week"], values: ["week", "last"]) == "Last week")
        #expect(Adaptive.selectedLabel("last", labels: ["This week", "Last week"], values: nil) == nil)
        #expect(Adaptive.selectedLabel("gone", labels: ["This week"], values: ["week"]) == nil)
    }

    @Test("a stepper title given as words wraps between them only")
    func stepperWords() throws {
        let narrow = try DesignContractMeasure.size(
            of: HLStepperHeader(verbatim: "Dienstag, 12. November", previous: {}, next: {}),
            width: 240,
            typeSize: .accessibility3
        )
        #expect(narrow.height > HLHitTarget.minimum, "the date wraps onto more lines: \(narrow.height)")
    }

    @Test("a choice row is as high as every row")
    func choiceRowHeight() throws {
        let row = try DesignContractMeasure.size(of: HLChoiceRow(title: Text(verbatim: "PDF"), isSelected: true) {})
        #expect(row.height >= HLLayout.rowMinHeight)
    }

    @Test("a single choice with a glyph keeps the row height and every share form has its own glyph")
    func choiceRowGlyph() throws {
        let row = try DesignContractMeasure.size(
            of: HLChoiceRow(title: Text(verbatim: "PDF"), symbol: "doc.richtext", isSelected: false) {}
        )
        #expect(row.height >= HLLayout.rowMinHeight)
        let symbols = UnifiedSharingStore.OutputForm.allCases.map(UnifiedSharingCopy.formSymbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("removing from a list is the red minus on a 44 pt area")
    func removeForm() throws {
        #expect(HLDeleteButton.removeSymbol == "minus.circle.fill")
        let button = try DesignContractMeasure.size(
            of: HLDeleteButton(form: .remove, action: .undoable {}),
            width: nil
        )
        #expect(button.width >= HLHitTarget.minimum)
        #expect(button.height >= HLHitTarget.minimum)
    }

    @Test("an inline symbol button draws a text-size symbol on a 44 pt area")
    func inlineIconButton() throws {
        #expect(HLIconButton.symbolFont(for: .inline) == .hlBody)
        #expect(HLIconButton.symbolFont(for: .standard) == .hlTitle3)
        let inline = try DesignContractMeasure.size(
            of: HLIconButton(systemImage: "xmark.circle.fill", label: "Remove", size: .inline) {},
            width: nil,
            typeSize: .accessibility3
        )
        #expect(inline.width == HLHitTarget.minimum)
        #expect(inline.height == HLHitTarget.minimum)
    }

    @Test("a loading symbol button keeps its size")
    func loadingIconButton() throws {
        let resting = try DesignContractMeasure.size(
            of: HLIconButton(systemImage: "sparkles", label: "Ask the coach") {}, width: nil
        )
        let loading = try DesignContractMeasure.size(
            of: HLIconButton(systemImage: "sparkles", label: "Ask the coach", isLoading: true) {}, width: nil
        )
        #expect(resting == loading)
    }

    @Test("the stepper's chevrons point back and forth")
    func stepperDirections() throws {
        #expect(HLStepperHeader.Direction.previous.systemImage == "chevron.left")
        #expect(HLStepperHeader.Direction.next.systemImage == "chevron.right")
        let header = try DesignContractMeasure.size(
            of: HLStepperHeader(title: Text(verbatim: "Dienstag"), previous: {}, next: {})
        )
        #expect(header.height >= HLHitTarget.minimum)
    }
}
