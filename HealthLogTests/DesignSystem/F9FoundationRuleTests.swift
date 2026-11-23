@testable import HealthLog
import SwiftUI
import Testing

/// The F9 foundation rules as pure functions: one card gap, the list margins
/// beside a bar on either side, the ring value floor, the stat grid's group
/// headings, the drawn check, the calm sparkline axis and the menu bar.
@MainActor
@Suite("F9 foundation rules")
struct F9FoundationRuleTests {
    @Test("tiles are cards: the tile gap is the card gap")
    func oneCardGap() {
        #expect(HLLayout.tileGap == HLLayout.cardGap)
        #expect(HLLayout.cardGap == 16)
    }

    @Test("beside an iPad sidebar the hidden stretch goes to the leading margin")
    func sidebarLeading() {
        let insets = HLPageMargins.listInsets(width: 853, scrollWidth: 1133, hiddenEdge: .leading)
        #expect(insets.leading == 280 + HLPageMargins.side(width: 853))
        #expect(insets.trailing == HLPageMargins.side(width: 853))
    }

    @Test("beside the Duo's upright bar on the right the stretch goes trailing")
    func duoBarTrailing() {
        let insets = HLPageMargins.listInsets(width: 382, scrollWidth: 466, hiddenEdge: .trailing)
        #expect(insets.leading == HLLayout.pageMargin)
        #expect(insets.trailing == 84 + HLLayout.pageMargin)
    }

    @Test("the hidden edge follows where the list starts and the layout direction")
    func hiddenEdge() {
        #expect(HLPageMargins.hiddenEdge(listMinX: 280, layoutDirection: .leftToRight) == .leading)
        #expect(HLPageMargins.hiddenEdge(listMinX: 0, layoutDirection: .leftToRight) == .trailing)
        #expect(HLPageMargins.hiddenEdge(listMinX: 0, layoutDirection: .rightToLeft) == .leading)
        #expect(HLPageMargins.hiddenEdge(listMinX: 280, layoutDirection: .rightToLeft) == .trailing)
    }

    @Test("without a bar both margins are the page side")
    func noBar() {
        for edge in [HorizontalEdge.leading, .trailing] {
            let insets = HLPageMargins.listInsets(width: 440, scrollWidth: 440, hiddenEdge: edge)
            #expect(insets.leading == HLLayout.pageMargin)
            #expect(insets.trailing == HLLayout.pageMargin)
        }
    }

    @Test("a ring value never reads smaller than the compact value role")
    func ringValueFloor() {
        #expect(HLScoreRing.centreValueSize(side: 60, scaledRatio: 0.22, compactSize: 17) == 17)
        #expect(HLScoreRing.centreValueSize(side: 160, scaledRatio: 0.22, compactSize: 17) == 160 * 0.22)
        #expect(HLScoreRing.centreValueSize(side: 60, scaledRatio: 0.22, compactSize: 23) == 23)
    }

    @Test("the first heading of a stat grid hears the page gap, later ones follow their row")
    func statGridHeadings() {
        let page = HLContainerGap(before: 16, after: 16)
        let first = HLStatGrid.headingGap(isFirst: true, page: page)
        let later = HLStatGrid.headingGap(isFirst: false, page: page)
        #expect(HLSectionHeaderMetrics.topPadding(in: first) + page.before == 24)
        #expect(HLSectionHeaderMetrics.topPadding(in: later) == 24)
        #expect(HLSectionHeaderMetrics.bottomPadding(in: first) == 8)
        #expect(HLSectionHeaderMetrics.bottomPadding(in: later) == 8)
    }

    @Test("the check is held undrawn only while unconfirmed and motion is allowed")
    func confirmGlyph() {
        #expect(HLConfirmGlyph.isHeldUndrawn(isConfirmed: false, reduceMotion: false))
        #expect(!HLConfirmGlyph.isHeldUndrawn(isConfirmed: true, reduceMotion: false))
        #expect(!HLConfirmGlyph.isHeldUndrawn(isConfirmed: false, reduceMotion: true))
        #expect(HLConfirmGlyph.isVisible(isConfirmed: true, reduceMotion: true))
        #expect(!HLConfirmGlyph.isVisible(isConfirmed: false, reduceMotion: true))
    }

    @Test("a calm series keeps its minimum span, centred, never below zero")
    func sparklineSpan() {
        let calm = HLSparkline.yDomain(values: [72.0, 73.6], minimumSpan: 4)
        #expect(calm.upperBound - calm.lowerBound == 4)
        #expect(abs((calm.lowerBound + calm.upperBound) / 2 - 72.8) < 0.0001)
        let nearZero = HLSparkline.yDomain(values: [0.5, 1.0], minimumSpan: 4)
        #expect(nearZero.lowerBound == 0)
        #expect(nearZero.upperBound - nearZero.lowerBound == 4)
        let wide = HLSparkline.yDomain(values: [50, 150], minimumSpan: 4)
        #expect(wide == 45 ... 155)
        let flat = HLSparkline.yDomain(values: [70, 70])
        #expect(flat == 69.5 ... 70.5)
    }

    @Test("the page's add action stands apart so it folds last")
    func addStandsApart() {
        let actions: HLTabHeaderActions = [
            .add(label: "Add") {},
            .coach {},
            .settings(label: "Settings") {}
        ]
        let split = HLPageActions.split(actions)
        #expect(split.primary?.role == .add)
        #expect(split.group.map(\.role) == [.settings, .coach])
    }

    @Test("period shortcuts follow the place, one to nine")
    func periodKeys() {
        #expect(HLPeriodCommand.key(forIndex: 0) == KeyEquivalent("1"))
        #expect(HLPeriodCommand.key(forIndex: 5) == KeyEquivalent("6"))
        #expect(HLPeriodCommand.key(forIndex: 9) == nil)
    }

    @Test("a sheet zooms out of its button unless motion is reduced")
    func zoomRule() {
        #expect(HLZoomTransitionRule.zooms(reduceMotion: false))
        #expect(!HLZoomTransitionRule.zooms(reduceMotion: true))
    }

    @Test("a tab header's actions stand in the system bar unless the page says otherwise")
    func actionPlacementDefault() {
        #expect(EnvironmentValues().hlTabHeaderActionPlacement == .bar)
    }

    @Test("only the page on screen, and in the pager only the active one, feeds the Period menu")
    func periodMenuSource() {
        #expect(HLPeriodCommandPublisher.publishes(isShown: true, isOnScreen: true, inPager: false, isActivePage: false))
        #expect(HLPeriodCommandPublisher.publishes(isShown: true, isOnScreen: true, inPager: true, isActivePage: true))
        #expect(!HLPeriodCommandPublisher.publishes(isShown: true, isOnScreen: true, inPager: true, isActivePage: false))
        #expect(!HLPeriodCommandPublisher.publishes(isShown: true, isOnScreen: false, inPager: false, isActivePage: false))
        #expect(!HLPeriodCommandPublisher.publishes(isShown: false, isOnScreen: true, inPager: false, isActivePage: false))
    }

    @Test("the capture picker keeps the form it opened in; a change of width closes it")
    func capturePickerFormIsFixed() {
        let opened = CapturePickerPopover.form(for: .regular)
        #expect(opened == .regular)
        // Open as a popover: only the popover shows, also after the window
        // turned compact, until the picker is closed.
        #expect(CapturePickerPopover.shows(.regular, isOpen: true, fixedForm: opened))
        #expect(!CapturePickerPopover.shows(.compact, isOpen: true, fixedForm: opened))
        #expect(CapturePickerPopover.closesOnResize(isOpen: true, fixedForm: opened, newSizeClass: .compact))
        #expect(!CapturePickerPopover.closesOnResize(isOpen: true, fixedForm: opened, newSizeClass: .regular))
        #expect(!CapturePickerPopover.closesOnResize(isOpen: false, fixedForm: opened, newSizeClass: .compact))
        #expect(CapturePickerPopover.closesOnResize(isOpen: true, fixedForm: .compact, newSizeClass: .regular))
    }

    @Test("closing on a change of width keeps the gate taken until the picker is gone, then + works again")
    func captureGateAcrossResize() {
        var gate = ShellSheetGate()
        #expect(gate.request(.capturePicker) == .present(.capturePicker))
        var isOpen = true
        let fixedForm = CapturePickerPopover.form(for: .regular)
        // The window turns compact while the popover is up.
        if CapturePickerPopover.closesOnResize(isOpen: isOpen, fixedForm: fixedForm, newSizeClass: .compact) {
            isOpen = false
        }
        #expect(!isOpen)
        // Nothing else may present while the popover is still leaving.
        #expect(gate.active == .capturePicker)
        #expect(!CapturePickerPopover.shows(.compact, isOpen: isOpen, fixedForm: fixedForm))
        #expect(gate.request(.mood) == .deferred)
        // The popover's own dismiss callback releases the gate; the parked
        // request follows, and once it is gone + opens the picker again.
        #expect(gate.didDismiss(.capturePicker) == .mood)
        #expect(gate.didDismiss(.mood) == nil)
        #expect(gate.request(.capturePicker) == .present(.capturePicker))
    }

    @Test("the capture picker is a popover in a regular window and a sheet on the phone")
    func capturePickerForm() {
        #expect(CapturePickerPopover.isPopover(sizeClass: .regular))
        #expect(!CapturePickerPopover.isPopover(sizeClass: .compact))
        #expect(!CapturePickerPopover.isPopover(sizeClass: nil))
    }
}
