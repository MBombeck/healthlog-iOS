import XCTest

/// The first entry in an empty GLP-1 journal swaps that journal from its row
/// in the add card to its full section. The add sheet hangs on the stack that
/// stays, so saving the first pen, side effect and titration step closes the
/// sheet cleanly and the row gives way to the section.
final class GLP1FirstEntryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFirstEntriesCloseTheirSheets() {
        let app = boot()
        openTrulicity(app)

        addFirstEntry(app, row: "glp1.add.pen")
        addFirstEntry(app, row: "glp1.add.sideEffect")
        addFirstEntry(app, row: "glp1.add.titrationStep") {
            let dose = app.textFields["glp1.titration.dose"]
            XCTAssertTrue(dose.waitForExistence(timeout: 10), "dose field missing")
            dose.tap()
            dose.typeText("0,75")
        }
    }

    private func addFirstEntry(_ app: XCUIApplication, row identifier: String, fill: () -> Void = {}) {
        let row = app.buttons[identifier]
        scrollTo(row, in: app)
        XCTAssertTrue(row.exists, "\(identifier) missing: the journal is not empty in the fixture")
        row.tap()

        // The sheet's confirm button, found by its identifier in any language.
        let save = app.navigationBars.buttons["glp1.sheet.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "\(identifier): the sheet did not open")
        fill()
        save.tap()

        XCTAssertTrue(save.waitForNonExistence(timeout: 15), "\(identifier): the sheet did not close after saving")
        XCTAssertFalse(app.buttons[identifier].exists, "\(identifier): the add row is still there after the first entry")
        attachScreenshot(app, name: identifier)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 12 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTrulicity(_ app: XCUIApplication) {
        XCTAssertTrue(ShellNavigator.select(symbol: "pills.fill", in: app, timeout: 20), "Medications tab missing")
        let card = app.descendants(matching: .any)["medications.card.mkshot-med-trulicity"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Trulicity card missing")
        card.tap()
    }

    private func boot() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(
            extraArguments: UITestLanguage.de.launchArguments + [
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                // Gives Trulicity its GLP-1 class, so the detail shows the journals.
                "-uitest-area-meds",
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
