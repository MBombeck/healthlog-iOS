import XCTest

/// The full-screen chart is the one place the phone may turn. On iOS 27 the
/// scene releases the landscape orientations while the cover is up and takes
/// them back when it closes. The case opens the cover, turns the device, sees
/// the window go wide, closes the cover and sees the window upright again.
/// The pad turns everywhere, so on the pad the window is wide in landscape
/// anyway; it still has to be upright after the turn back.
@MainActor
final class FullscreenChartOrientationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isRegular = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = AdaptiveShell.launch()
        isRegular = AdaptiveShell.isRegular(app)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func test_fullscreenChartTurnsToLandscapeAndBackUprightOnClose() {
        openFullscreenChart()
        XCTAssertTrue(isUpright, "the app starts the chart upright")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { !self.isUpright }, "the full-screen chart did not turn to landscape")
        let dismiss = app.buttons["chartDetail.fullscreen.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "the cover lost its close button in landscape")

        dismiss.tap()
        XCTAssertTrue(waitUntil { !dismiss.exists }, "the cover did not close")
        // A regular window (the pad, the Duo's inner display) follows the
        // device in every orientation, so it stays wide until the device is
        // turned back; a compact window has to right itself.
        if isRegular { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(waitUntil { self.isUpright }, "the app did not stand upright again after the cover closed")
    }

    private var isUpright: Bool {
        let frame = AdaptiveShell.windowFrame(in: app)
        return frame.height > frame.width
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Blood pressure page by link, then a tap on the chart card. The chart's
    /// scrub gesture takes a tap on the plot, so the card is tapped in its
    /// leading padding, left of the plot.
    private func openFullscreenChart() {
        AdaptiveShell.open("healthlog://insights/blood-pressure")
        let window = AdaptiveShell.windowFrame(in: app)
        let cards = app.descendants(matching: .any).matching(identifier: "chart.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 30), "the metric page did not open")
        /// The pager keeps its neighbours alive; the card on screen is the one.
        /// On a short window it may stand below the fold, so the page scrolls.
        func cardOnScreen() -> XCUIElement? {
            cards.allElementsBoundByIndex.first {
                $0.frame.midX > 0 && $0.frame.midX < window.width && $0.frame.minY > 0 && $0.isHittable
            }
        }
        for _ in 0 ..< 3 where cardOnScreen() == nil {
            app.swipeUp()
        }
        guard let card = cardOnScreen() else {
            XCTFail("no chart card on screen")
            return
        }
        let dismiss = app.buttons["chartDetail.fullscreen.dismiss"]
        card.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 6, dy: card.frame.height / 2))
            .tap()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 8), "the chart did not open full screen")
    }
}
