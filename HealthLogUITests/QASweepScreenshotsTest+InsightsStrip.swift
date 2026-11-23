import XCTest

/// The Insights strip under the page titles and its pinned form: a chip far
/// to the right, a page read far down with the pinned strip, a page change
/// from the pinned strip, a deep link to a late metric. Then the coach sheet
/// from the overview head and the life circumstances under About me. Runs with
/// the sweep's language, appearance and text size. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_26_insightsStrip() {
        boot(extra: ["-uitest-life"])
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        settle(3)

        // The far end of the strip: drag it left, tap a chip in the middle
        // (the last element is the customise pill).
        let strip = element("insights.tabStrip")
        if strip.waitForExistence(timeout: 8) {
            strip.swipeLeft()
            strip.swipeLeft()
            settle(1)
            strip.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
            settle(3)
        } else {
            note("strip not found")
        }
        shot("26-strip-far-chip")

        // Read far down: the strip under the title goes, the pinned one stands.
        for _ in 0 ..< 3 {
            scrollDown()
        }
        shot("26-strip-pinned")

        // Change the page from the pinned strip, still scrolled.
        let pinned = element("insights.tabStrip")
        if pinned.exists {
            pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            settle(3)
        } else {
            note("pinned strip not found")
        }
        shot("26-strip-switched")

        // A deep link to a metric late in the strip.
        openDeepLink("healthlog://insights/oxygen")
        settle(5)
        shot("26-strip-deeplink-oxygen")

        // The coach sheet from the overview head.
        // A second tap on the tab returns the pager to the overview's top.
        tab("sparkles")
        settle(2)
        if tap(element("InsightsScreen.askCoachCollapsedCoin.header"), "coach circle") {
            settle(3)
            shot("26-coach-sheet")
            let close = app.navigationBars.buttons.element(boundBy: 0)
            if close.exists, close.isHittable { close.tap() }
            settle(1)
        }

        // Life circumstances under About me.
        tab("ellipsis")
        guard tap(element("more.row.about_me"), "about me row") else { return }
        settle(2)
        guard let life = probe("aboutMe.row.lifeCircumstances") else {
            note("life circumstances row not on screen")
            return
        }
        life.tap()
        settle(4)
        shotPair("26-life")
    }
}
