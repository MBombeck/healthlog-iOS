import XCTest

/// The privacy cover is an overlay, never a teardown: what a person has typed
/// into a form survives Home and the way back. Home takes the app through
/// `.inactive` into `.background` and back through `.inactive` to `.active`,
/// so one round trip covers both phases. The biometric lock is off in these
/// runs (it unmounts the tree on purpose and has its own tests).
@MainActor
final class PrivacyCoverStateUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = AdaptiveShell.launch()
    }

    func test_formInputSurvivesHomeAndReturn() {
        XCTAssertTrue(ShellNavigator.select(tab: .log, in: app), "the Log tab is missing")
        let row = app.descendants(matching: .any)["capture.picker.row.measurement"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the capture picker did not open")
        row.tap()
        let marker = app.descendants(matching: .any)["measure-sheet.recordedAt.picker"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 15), "the measurement sheet did not open")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet has no input field")
        field.tap()
        field.typeText("72.5")
        XCTAssertEqual(field.value as? String, "72.5")

        for round in 1 ... 2 {
            XCUIDevice.shared.press(.home)
            // The home screen is the witness that the app left the foreground;
            // the app's own state is read late on the simulator.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let left = springboard.icons["HealthLog"].waitForExistence(timeout: 10) || app.state != .runningForeground
            XCTAssertTrue(left, "round \(round): Home did not leave the app")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "round \(round): the app did not come back")
            XCTAssertTrue(marker.waitForExistence(timeout: 10), "round \(round): the sheet is gone after the way back")
            XCTAssertEqual(
                app.textFields.firstMatch.value as? String, "72.5",
                "round \(round): the typed value did not survive Home"
            )
        }
    }
}
