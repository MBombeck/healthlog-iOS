import XCTest

/// The More page's actions stand in the system bar and stay there while the
/// list scrolls: a list row that scrolls away must not take them along.
@MainActor
final class F9ABarActionsUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_more_gear_stays_in_the_bar_after_scrolling() {
        let app = XCUIApplication()
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)

        XCTAssertTrue(ShellNavigator.select(tab: .more, in: app), "More tab missing")

        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Gear missing before scrolling")

        // Scroll the header row well out of the list's visible part.
        for _ in 0 ..< 3 {
            app.swipeUp()
        }

        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Gear left the bar when the list scrolled")
        XCTAssertTrue(gear.isHittable, "Gear is in the tree but not reachable after scrolling")
    }
}
