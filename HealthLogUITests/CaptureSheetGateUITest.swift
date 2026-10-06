import XCTest

/// #115 · 1.1 T1 — the shell's sheet gate driven through the real tab bar.
///
/// TestFlight 1.1.0 (286) aborted when a shell sheet preempted a presentation
/// that was still on screen ("Dando al botón + se ha cerrado la App"). The crash
/// itself needs iOS 27's zoom morph and did not reproduce on the 26.5 simulator;
/// what these cases pin is the ordering the fix guarantees there: a burst of "+"
/// taps never stacks a second picker or wedges the "+", and "+" during the
/// staged hand-off cannot replace the follow-up sheet. (A router-driven request
/// cannot be driven from XCUITest: `XCUIApplication.open(_:)` relaunches the
/// app, so that ordering is covered by `ShellSheetGateTests`.)
@MainActor
final class CaptureSheetGateUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_rapidPlusTapsRaiseOnePicker() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 60)
        XCTAssertTrue(plusButton(app).waitForExistence(timeout: 10), "Erfassen tab button missing")
        for _ in 0 ..< 6 {
            tapPlus(app)
        }
        // Once the picker is up, the later taps land on its bottom row (the
        // "+" sits under the "Stimmung erfassen" row) and stage the mood sheet,
        // so the burst ends on whatever surface the gate let through. What must
        // hold: the app is alive, there is never more than one picker, and the
        // gate is not wedged — after clearing the stage, one calm tap on "+"
        // raises the picker again.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "app died on a burst of + taps")
        let row = app.descendants(matching: .any).matching(identifier: "capture.picker.row.measurement")
        XCTAssertLessThanOrEqual(row.count, 1, "more than one capture picker on screen")
        for _ in 0 ..< 3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(app.state, .runningForeground, "app died while the burst's sheets dismissed")
        tapPlus(app)
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "the capture picker no longer opens after a + burst")
        XCTAssertEqual(row.count, 1, "more than one capture picker on screen")
    }

    func test_plusDuringHandOffKeepsTheFollowUpSheet() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 60)
        XCTAssertTrue(plusButton(app).waitForExistence(timeout: 10), "Erfassen tab button missing")
        tapPlus(app)
        let row = app.descendants(matching: .any).matching(identifier: "capture.picker.row.measurement").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "capture picker did not open")
        row.tap()
        for _ in 0 ..< 4 {
            tapPlus(app)
        }
        let measureSheet = app.descendants(matching: .any).matching(identifier: "measure-sheet.recordedAt.picker").firstMatch
        XCTAssertTrue(measureSheet.waitForExistence(timeout: 8), "the staged measure sheet never presented")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "app died on + during the capture hand-off")
        XCTAssertTrue(measureSheet.exists, "a + tap replaced the measure sheet")
        XCTAssertFalse(row.exists, "a second capture picker preempted the measure sheet")
    }

    // MARK: - Helpers

    private func plusButton(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons.containing(.image, identifier: "plus.circle.fill").firstMatch
    }

    /// Taps the bar button by coordinate so the tap lands even while a sheet is
    /// animating over the bar (the race the gate exists for).
    private func tapPlus(_ app: XCUIApplication) {
        let frame = plusButton(app).frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
    }
}
