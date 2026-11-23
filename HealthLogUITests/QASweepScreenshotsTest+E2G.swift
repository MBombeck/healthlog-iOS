import XCTest

/// The Insights overview with the health score beside the other scores and
/// its detail, then Recovery as a category: the pill's menu, the first
/// recovery page (by the old recovery address) and the next one a swipe
/// away. Runs with the sweep's language, appearance and text size. Only runs
/// when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_33_insightsStructure() {
        boot()
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        settle(3)
        shot("33-overview-top")

        // The score grid with the health score card.
        if let card = probe("insights.scoreCard.HEALTH_SCORE") {
            shot("33-overview-scores")
            card.tap()
            settle(3)
            shot("33-healthscore-sheet")
            app.swipeUp()
            settle(1.5)
            shot("33-healthscore-sheet-end")
            dismissSheet()
        } else {
            note("health score card not found")
        }
        scrollUpToTop()

        // Recovery as a category: the pill opens the menu of its pages.
        if tap(element("insights.tabStrip.pill.group.recovery"), "recovery category pill") {
            settle(1.5)
            shot("33-recovery-menu")
            // Close the menu where nothing else reacts: the title.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            settle(1)
        }
        // The old address of the recovery page opens the first recovery page.
        openDeepLink("healthlog://insights/recovery")
        settle(5)
        shot("33-recovery-first")
        if let page = visibleInsightsPage() {
            note("recovery first page: \(page)")
        }
        scrollDown()
        shot("33-recovery-first-scroll1")
        scrollUpToTop()

        // The next recovery page, one swipe on, over the title.
        let window = app.windows.firstMatch
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1))
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
        right.press(forDuration: 0.05, thenDragTo: left)
        settle(3)
        shot("33-recovery-second")
        if let page = visibleInsightsPage() {
            note("recovery second page: \(page)")
        }
    }
}
