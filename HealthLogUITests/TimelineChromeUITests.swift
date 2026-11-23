import XCTest

/// **Held across, the timeline's bar steps aside after a rest and comes
/// back with a touch; an open menu keeps it.**
///
/// On a phone with iOS 27 the timeline opens across in its full screen; every
/// control stands in the bar at the top there. The rules themselves are
/// `TimelineChromeTests`; this walks them on the real page, so the touch
/// observer, the menu's open state and the bar's visibility are proven
/// together. On a display without the full screen (iPad, iOS 26) there is
/// nothing to hide and the test says so.
///
/// World: the hermetic boot with the timeline fixture server (1.47.1, the
/// module on).
@MainActor
final class TimelineChromeUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_barRestsAndComesBackAndMenuHoldsIt() throws {
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-uitest-timeline",
                "-hl.healthkit.serverVersion", "1.47.1",
                "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
                "-hl.healthkit.waistReadRequested.hermetic-user", "true",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        try XCUIDevice.shared.system.open(XCTUnwrap(URL(string: "healthlog://timeline")))
        let close = app.buttons["timeline.across.close"]
        guard close.waitForExistence(timeout: 15) else {
            throw XCTSkip("no turned full screen on this display: the bar never rests here")
        }
        XCTAssertTrue(app.descendants(matching: .any)["timeline.board"].waitForExistence(timeout: 15), "the board did not load")

        // The rest: three and a half seconds without a touch.
        XCTAssertTrue(waitForAbsence(close, timeout: 8), "the bar did not step aside after the rest")

        // A touch on the board brings it back, and it rests again.
        XCTAssertTrue(app.revealTimelineControls(), "a touch on the board did not bring the bar back")
        XCTAssertTrue(waitForAbsence(close, timeout: 8), "the bar did not rest again after the touch")

        // An open menu holds the bar, longer than a rest.
        XCTAssertTrue(app.revealTimelineControls(waitingFor: "timeline.across.choices"), "the menu button did not come back")
        app.buttons["timeline.across.choices"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let lanes = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Laborwerte", "Lab values"])).firstMatch
        XCTAssertTrue(lanes.waitForExistence(timeout: 5), "the menu of lines and lanes did not open")
        pause(5)
        XCTAssertTrue(lanes.exists, "the open menu was taken away with the bar")
        XCTAssertTrue(app.buttons["timeline.across.choices"].exists, "the bar left while its menu was open")

        // Closed with a tap beside it; the next touch on the page starts the rest again.
        let board = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        board.tap()
        pause(1)
        board.tap()
        XCTAssertTrue(
            waitForAbsence(app.buttons["timeline.across.choices"], timeout: 8),
            "the bar did not rest after the menu closed and the page was touched"
        )
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
