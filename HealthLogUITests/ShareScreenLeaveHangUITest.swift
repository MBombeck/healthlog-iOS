import XCTest

/// **G1 — leaving the scrolled Share screen must not freeze the app.**
///
/// The App Store screenshot run found it: in English, Share (Mehr → header
/// share glyph) scrolled down, then the Insights tab — the main thread spun at
/// 100 % in `LazySubviewPlacements.placeSubviews` → `LazyStack.place` and every
/// UI query timed out. It is not about Insights, nor about English: any way of
/// leaving the screen (another tab, the Back button) froze it, as long as the
/// scroll had stopped with a card's top edge a few points below the visible
/// bottom edge. English text simply put a card edge there for the anchor the
/// screenshot run scrolled to. The cause was the lazy stack in `HLSettingsPage`
/// (see `HLSettingsPageEagerStackTests`).
///
/// Both tests drag without momentum so the scroll stops exactly where the
/// freeze was reproduced (the `period` card's top edge near y = 150 on the
/// iPhone 17 Pro Max). A hung main thread fails the next query, so each test
/// ends by asking for something on the screen it left for.
@MainActor
final class ShareScreenLeaveHangUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_switching_to_insights_after_scrolling_share_keeps_the_app_responsive() {
        let app = openScrolledShareScreen()

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(
            app.staticTexts["insights.page.header.title.overview"].waitForExistence(timeout: 20),
            "Insights never appeared after leaving the scrolled Share screen — main thread hung?"
        )
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 20),
            "The app stopped answering after the tab switch"
        )
    }

    func test_going_back_from_scrolled_share_keeps_the_app_responsive() {
        let app = openScrolledShareScreen()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.buttons["more.toolbar.share"].waitForExistence(timeout: 20),
            "More never reappeared after Back from the scrolled Share screen — main thread hung?"
        )
    }

    // MARK: - Steps

    /// Hermetic English boot → Mehr → Share → select everything → drag the
    /// period card up to y ≈ 150.
    private func openScrolledShareScreen() -> XCUIApplication {
        let app = XCUIApplication()
        _ = app.launchHermeticAndWaitForDashboard(
            extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            timeout: 120
        )
        // The screenshot run's pace: let every store hydrate first, so the
        // Share cards have their final heights when the scroll stops.
        Thread.sleep(forTimeInterval: 12)

        let moreTab = app.tabBars.buttons.element(boundBy: max(0, app.tabBars.buttons.count - 1))
        XCTAssertTrue(moreTab.waitForExistence(timeout: 15), "More tab missing")
        moreTab.tap()
        let shareGlyph = app.buttons["more.toolbar.share"]
        XCTAssertTrue(shareGlyph.waitForExistence(timeout: 15), "Header share glyph missing")
        shareGlyph.tap()
        let selectAll = app.buttons["sharing.unified.selectAll"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 20), "Share screen did not hydrate")
        selectAll.tap()
        Thread.sleep(forTimeInterval: 5)

        drag(app: app, anchor: "sharing.unified.period", toY: 150)
        return app
    }

    /// Drags until the `anchor` element's top edge sits at `targetY`, or the
    /// scroll view stops following. Pressing, dragging and holding before the
    /// lift leaves no momentum, so the content stops where the finger did.
    private func drag(app: XCUIApplication, anchor: String, toY targetY: CGFloat) {
        let element = app.descendants(matching: .any).matching(identifier: anchor).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Scroll anchor \(anchor) missing")
        let window = app.windows.firstMatch
        var lastY = CGFloat.infinity
        for _ in 0 ..< 6 {
            let minY = element.frame.minY
            let delta = minY - targetY
            if abs(delta) < 2 || abs(minY - lastY) < 1 { break }
            lastY = minY
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
                .withOffset(CGVector(dx: 0, dy: 500))
            let end = start.withOffset(CGVector(dx: 0, dy: -delta))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 150, thenHoldForDuration: 0.6)
            Thread.sleep(forTimeInterval: 1.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
