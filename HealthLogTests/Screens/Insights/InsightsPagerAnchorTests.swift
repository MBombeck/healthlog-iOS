import CoreGraphics
@testable import HealthLog
import Testing

/// The pager's page survives a change of its width. Every page is as wide as
/// the pager, so after a fold, a resize or a turn the scroll offset lies in
/// another page and the position report names a page nobody chose. At rest
/// that report would become the selection; the anchor brings the page of the
/// selection back under the snap and keeps the reports on the way out.
@MainActor
@Suite("Insights pager anchor across a width change")
struct InsightsPagerAnchorTests {
    private let ordered: [InsightsTabSelection] = [
        .overview, .metric(.bloodPressure), .metric(.weight), .metric(.pulse), .special(.mood)
    ]

    private var pages: [InsightsPagerPage] {
        InsightsPagerPage.pages(from: ordered)
    }

    /// A pager at rest on the weight page.
    private func restingOnWeight() -> InsightsPagerModel {
        let model = InsightsPagerModel()
        model.pagerOrder = ordered
        model.selection = .metric(.weight)
        model.scrolledID = .metric(.weight)
        model.pagerScrollPhaseChanged(isIdle: true, pages: pages, liveOrderedSelections: ordered)
        return model
    }

    // MARK: - The rule

    @Test(
        "only a real width change at rest snaps back",
        arguments: [
            (CGFloat(402), CGFloat(669), false, true),
            (669, 466, false, true),
            (1032, 1376, false, true),
            (669, 669, false, false),
            (669, 669.3, false, false),
            (0, 669, false, false),
            (669, 0, false, false),
            (466, 669, true, false)
        ]
    )
    func rule(old: CGFloat, new: CGFloat, isScrolling: Bool, expected: Bool) {
        #expect(InsightsPagerAnchor.needsReanchor(oldWidth: old, newWidth: new, isScrolling: isScrolling) == expected)
    }

    @Test("the anchor is the page of the selection")
    func anchorIsTheSelection() {
        #expect(InsightsPagerAnchor.anchor(for: .metric(.weight), in: pages) == .metric(.weight))
        #expect(InsightsPagerAnchor.anchor(for: .special(.mood), in: pages) == .special(.mood))
        #expect(InsightsPagerAnchor.anchor(for: .metric(.sleep), in: pages) == nil)
    }

    // MARK: - The page holds

    @Test("without the anchor a report after the resize would move the selection")
    func driftWithoutAnchorMovesTheSelection() {
        // The structural risk the anchor answers: at rest a report wins.
        let model = restingOnWeight()
        model.scrolledID = .metric(.pulse)
        model.adoptScrolledPage(.metric(.pulse), pages: pages, liveOrderedSelections: ordered)
        #expect(model.selection == .metric(.pulse))
    }

    @Test("a position that still names the page snaps back without a latch")
    func heldPositionNeedsNoLatch() {
        let model = restingOnWeight()
        let generation = model.programmaticScrollGeneration
        #expect(model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages) == .metric(.weight))
        #expect(model.programmaticScrollTarget == nil)
        #expect(model.programmaticScrollGeneration == generation)
        #expect(model.selection == .metric(.weight))
    }

    @Test("a swipe right after a width change counts at once")
    func swipeAfterWidthChange() {
        let model = restingOnWeight()
        model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages)
        model.pagerScrollPhaseChanged(isIdle: false, isUserDriven: true, pages: pages, liveOrderedSelections: ordered)
        model.scrolledID = .metric(.pulse)
        model.pagerScrollPhaseChanged(isIdle: true, pages: pages, liveOrderedSelections: ordered)
        #expect(model.selection == .metric(.pulse))
    }

    @Test("folding open with a drifted position: the reports on the way are ignored, the snap lands on the page")
    func foldKeepsThePage() {
        let model = restingOnWeight()
        // The position drifted with the width before the width change arrived.
        model.scrolledID = .metric(.pulse)
        let anchor = model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages)
        #expect(anchor == .metric(.weight))
        #expect(model.scrolledID == .metric(.weight))
        #expect(model.programmaticScrollTarget == .metric(.weight))

        // The resize reports neighbour pages on its way…
        model.adoptScrolledPage(.metric(.pulse), pages: pages, liveOrderedSelections: ordered)
        model.adoptScrolledPage(.metric(.bloodPressure), pages: pages, liveOrderedSelections: ordered)
        #expect(model.selection == .metric(.weight))

        // …and the snap lands on the remembered page, which frees the latch.
        model.adoptScrolledPage(.metric(.weight), pages: pages, liveOrderedSelections: ordered)
        #expect(model.programmaticScrollTarget == nil)
        #expect(model.selection == .metric(.weight))
        #expect(model.scrolledID == .metric(.weight))
    }

    @Test("a finger on the pager ends the latch while it waits")
    func fingerEndsTheLatch() {
        let model = restingOnWeight()
        model.scrolledID = .metric(.pulse)
        model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages)
        #expect(model.programmaticScrollTarget != nil)
        model.pagerScrollPhaseChanged(isIdle: false, isUserDriven: true, pages: pages, liveOrderedSelections: ordered)
        #expect(model.programmaticScrollTarget == nil)
        model.scrolledID = .special(.mood)
        model.pagerScrollPhaseChanged(isIdle: true, pages: pages, liveOrderedSelections: ordered)
        #expect(model.selection == .special(.mood))
    }

    @Test("a drifted position is set back to the page of the selection")
    func driftedPositionIsSetBack() {
        let model = restingOnWeight()
        model.scrolledID = .metric(.pulse)
        model.reanchorAfterWidthChange(oldWidth: 669, newWidth: 466, pages: pages)
        #expect(model.scrolledID == .metric(.weight))
        #expect(model.selection == .metric(.weight))
    }

    @Test("turning the iPad and back keeps the page")
    func turnAndBack() {
        let model = restingOnWeight()
        model.reanchorAfterWidthChange(oldWidth: 1032, newWidth: 1376, pages: pages)
        model.reanchorAfterWidthChange(oldWidth: 1376, newWidth: 1032, pages: pages)
        #expect(model.selection == .metric(.weight))
        #expect(model.scrolledID == .metric(.weight))
        #expect(model.programmaticScrollTarget == nil)
    }

    @Test("the backstop releases a stale latch and lets the shown page be the selection")
    func backstopKeepsPageAndPillTogether() {
        let model = restingOnWeight()
        model.scrolledID = .metric(.pulse)
        model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages)
        // No report landed; the pager shows the page it shows.
        model.scrolledID = .metric(.weight)
        model.releaseStaleReanchor(
            generation: model.programmaticScrollGeneration,
            pages: pages,
            liveOrderedSelections: ordered
        )
        #expect(model.programmaticScrollTarget == nil)
        #expect(model.selection == .metric(.weight))
    }

    @Test("no snap while the pager moves or before the first measure")
    func noSnapWhileMoving() {
        let model = restingOnWeight()
        model.isPagerScrolling = true
        model.scrolledID = .metric(.pulse)
        #expect(model.reanchorAfterWidthChange(oldWidth: 466, newWidth: 669, pages: pages) == nil)
        #expect(model.programmaticScrollTarget == nil)
        model.isPagerScrolling = false
        #expect(model.reanchorAfterWidthChange(oldWidth: 0, newWidth: 669, pages: pages) == nil)
        #expect(model.programmaticScrollTarget == nil)
    }
}
