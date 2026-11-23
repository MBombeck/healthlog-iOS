import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The header, sheet and glass blocks: the tab header's action group, the
/// info sheet, the confirm of a pushed page, the dismiss of a card, the
/// bottom bar, the one pull-to-refresh and the opaque content surfaces.
@MainActor
@Suite("E-P0b header and glass blocks")
struct EP0bHeaderGlassContractTests {
    private typealias Role = HLTabHeaderAction.Role

    // MARK: - Tab header actions

    @Test("actions stand from the title outwards: info, setting, coach, add")
    func fixedOrder() {
        let actions: HLTabHeaderActions = [
            .add(label: "Add medication") {},
            .coach {},
            .settings(label: "Adjust target range") {},
            .info(Self.info, identifier: "test.info")
        ]
        #expect(actions.items.map(\.role) == [.info, .settings, .coach, .add])
        #expect(actions.items.map(\.systemImage) == ["info.circle", "slider.horizontal.3", "sparkles", "plus"])
    }

    @Test("one action per role, the first one given wins")
    func onePerRole() {
        let actions: HLTabHeaderActions = [
            .add(label: "Add medication", identifier: "first") {},
            .add(label: "Add medication", identifier: "second") {}
        ]
        #expect(actions.items.count == 1)
        #expect(actions.items.first?.identifier == "first")
    }

    @Test("up to three actions show; past that the inner ones fold into More")
    func folding() {
        let three = HLTabHeaderActions.arrangement(of: [.coach, .info, .settings])
        #expect(three.visible == [.info, .settings, .coach])
        #expect(three.folded.isEmpty)
        let four = HLTabHeaderActions.arrangement(of: [.add, .coach, .settings, .info])
        #expect(four.visible == [.coach, .add], "add keeps the trailing edge, More takes the third place")
        #expect(four.folded == [.info, .settings])
        #expect(HLTabHeaderMetrics.maxVisibleActions == 3)
        #expect(HLTabHeaderActionGroup.moreSymbol == "ellipsis")
    }

    @Test("a pushed page's header has no actions")
    func noneIsEmpty() {
        #expect(HLTabHeaderActions.none.items.isEmpty)
    }

    @Test("inside the header group a bar button draws no glass of its own")
    func noGlassOnGlass() {
        let resting = HLIconButton.appearance(style: .bar, isSelected: false, inGroup: true)
        #expect(resting.surface == .none)
        #expect(resting.ink == .resting)
        let chosen = HLIconButton.appearance(style: .bar, isSelected: true, inGroup: true)
        #expect(chosen.surface == .selected, "a filter in force still shows as chosen")
        #expect(HLIconButton.appearance(style: .bar, isSelected: false).surface == .glass, "alone it keeps its circle")
        #expect(HLIconButton.appearance(style: .plain, isSelected: false, inGroup: true).surface == .none)
    }

    // MARK: - Sheets and bars

    @Test("the info sheet closes with the cross and confirms nothing")
    func infoSheet() {
        #expect(HLInfoSheet.action.kind == .closeOnly)
        #expect(HLSheetBar.showsClose(for: HLInfoSheet.action.kind))
        #expect(HLInfoSheet.action.confirmLabel == nil)
        #expect(HLInfoPage.externalSymbol == "arrow.up.right")
    }

    @Test("a pushed page in a sheet confirms with the same spoken word as the sheet")
    func confirmBar() {
        #expect(HLSheetAction.save { true }.confirmLabel == HLControlWord.save.text)
        #expect(HLSheetAction.none.confirmLabel == nil, "a page with nothing to keep shows no check mark")
    }

    @Test("a card is put away with the bare cross")
    func dismiss() {
        #expect(HLDismissButton.systemImage == "xmark")
    }

    @Test("the bottom bar lines up with the cards")
    func bottomBar() {
        #expect(HLBottomBarMetrics.horizontalInset == HLLayout.pageMargin)
        #expect(HLBottomBarMetrics.verticalInset == HLSpace.sm)
    }

    @Test("one pull-to-refresh: the app glyph on a scroll view, the system's on a list")
    func refresh() {
        #expect(HLRefreshHost.scrollView.mechanism == .appGlyph)
        #expect(HLRefreshHost.list.mechanism == .system)
    }

    @Test("content surfaces are opaque, the glass card is gone")
    func opaqueContent() {
        #expect(HLCardSurface.content == .opaque)
        let appearance = InsightsTileStyle.shippingDefault.appearance(signal: nil)
        #expect(appearance.surface == .mono)
    }

    private static let info = HLInfoContent(title: "Puls", identifier: "test.info.sheet", about: "Text")
}
