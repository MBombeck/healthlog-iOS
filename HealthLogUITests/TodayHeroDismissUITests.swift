import XCTest

/// A dismissible hint with one action on Today: the whole card opens its
/// target, a sideways swipe (like a mail in Mail) only removes the card. The
/// card carries no mark of its own; VoiceOver and the long-press menu offer
/// the same as "Ausblenden".
@MainActor
final class TodayHeroDismissUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTappingTheCardOpensItsTarget() {
        let app = boot()
        let card = hintCard(app)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["insights.page.header.title.overview"].waitForExistence(timeout: 20),
            "tapping the hint card did not open the Insights overview"
        )
    }

    func testSwipingTheCardAwayRemovesItWithoutNavigating() {
        let app = boot()
        let card = hintCard(app)
        card.swipeLeft(velocity: .fast)
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the dismissed hint card is still on Today")
        XCTAssertFalse(
            app.descendants(matching: .any)["insights.page.header.title.overview"].waitForExistence(timeout: 3),
            "dismissing the hint navigated to Insights"
        )
        XCTAssertTrue(app.staticTexts["dashboard.greeting"].exists, "dismissing the hint left Today")
    }

    // MARK: - Helpers

    private func hintCard(_ app: XCUIApplication) -> XCUIElement {
        let card = app.buttons["dashboard.todayHero.worthALook.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no dismissible hint card on Today")
        XCTAssertTrue(card.isHittable, "the hint card is not on screen")
        return card
    }

    private func boot() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(
            extraArguments: UITestLanguage.de.launchArguments + [
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-uitest-hero-dismissible",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap() }
        return app
    }
}
