import XCTest

/// The measurement sheet takes its shape from the window that presents it.
/// Compact: a bottom sheet with the grabber, as wide as the window. Regular:
/// a form sheet, centered and narrower than the window, without a grabber.
/// The sheet's own bar gives the measure: the leading close button and the
/// trailing confirm button sit at the sheet's edges. One case runs in both
/// windows and checks the branch it is in (`AdaptiveShell.isRegular`).
@MainActor
final class SheetSizingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = AdaptiveShell.launch()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func test_measurementSheetIsABottomSheetCompactAndAFormSheetRegular() {
        let isRegular = AdaptiveShell.isRegular(app)
        if AdaptiveShell.deviceIsPad {
            XCTAssertTrue(isRegular, "the pad must offer the sidebar button; the regular branch would not run")
        }
        openMeasurementSheet()

        let close = app.buttons["hl.sheet.close"].firstMatch
        let confirm = app.buttons["hl.sheet.confirm"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the sheet has no close button")
        XCTAssertTrue(confirm.exists, "the sheet has no confirm button")
        let window = AdaptiveShell.windowFrame(in: app)
        let sheetWidth = confirm.frame.maxX - close.frame.minX
        let grabber = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] 'grabber' OR identifier CONTAINS[c] 'grabber'"
        )).firstMatch

        if isRegular {
            XCTAssertFalse(grabber.exists, "a form sheet has no grabber")
            XCTAssertLessThan(sheetWidth, window.width * 0.85, "a form sheet must be narrower than the window")
            XCTAssertGreaterThan(close.frame.minX, window.width * 0.1, "a form sheet stands clear of the window edge")
            XCTAssertEqual(
                (close.frame.minX + confirm.frame.maxX) / 2, window.midX, accuracy: window.width * 0.08,
                "a form sheet is centered"
            )
            // The form sheet ends a page inset below its last row: neither a
            // field cut off nor a stretch of empty sheet under the note.
            let note = app.textFields["measure-sheet.note"].firstMatch.exists
                ? app.textFields["measure-sheet.note"].firstMatch
                : app.textViews["measure-sheet.note"].firstMatch
            let form = app.collectionViews.containing(.any, identifier: "measure-sheet.recordedAt.picker").firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 5), "the note field is missing")
            XCTAssertTrue(form.exists, "the form is missing")
            let gap = form.frame.maxY - note.frame.maxY
            XCTAssertGreaterThanOrEqual(gap, 16, "the note field is cut off at the sheet's bottom (\(gap) pt)")
            XCTAssertLessThanOrEqual(gap, 90, "the sheet is taller than its form (\(gap) pt below the note)")
            // With the note focused the sheet keeps its height: the keyboard
            // is not counted, so the sheet does not rock with it.
            let formHeight = form.frame.height
            note.tap()
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(form.frame.height, formHeight, accuracy: 2, "the sheet changed height with the keyboard")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "measure-sheet-regular"
            shot.lifetime = .keepAlways
            add(shot)
        } else {
            XCTAssertTrue(grabber.exists, "a compact sheet shows the grabber")
            XCTAssertGreaterThan(sheetWidth, window.width * 0.8, "a compact sheet spans the window")
        }
        AdaptiveShell.attachTree(of: app, named: "measurement-sheet-tree", to: self)
    }

    /// The mood check-in has the head of every other sheet in a regular
    /// window: no grabber, the close button leading, the title inline in the
    /// bar. Compact it keeps the grabber and its hero title.
    func test_moodSheetHasTheCommonHeadAndFitsItsContent() {
        let isRegular = AdaptiveShell.isRegular(app)
        XCTAssertTrue(ShellNavigator.select(tab: .log, in: app), "the Log tab is missing")
        let row = app.descendants(matching: .any)["capture.picker.row.mood"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the capture picker did not open")
        row.tap()
        let grabber = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] 'grabber' OR identifier CONTAINS[c] 'grabber'"
        )).firstMatch
        let titles = ["How are you?", "Wie geht's dir?", "Hoe gaat het met je?"]
        let heroOrBar = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        XCTAssertTrue(heroOrBar.waitForExistence(timeout: 15), "the mood sheet did not open")
        Thread.sleep(forTimeInterval: 1.5)
        if isRegular {
            let close = app.buttons["hl.sheet.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "the form sheet has no close button")
            XCTAssertFalse(grabber.exists, "a form sheet has no grabber")
            XCTAssertLessThan(abs(heroOrBar.frame.midY - close.frame.midY), 12, "the title is not inline with the close button")
            // The faces' labels are the last line; the sheet ends a page
            // inset under them, not at the form sheet's full height.
            let awful = ["Awful", "Lausig", "Vreselijk"]
            let lastLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", awful)).firstMatch
            XCTAssertTrue(lastLabel.exists, "the faces are missing")
            // The form sheet stands at its final size from the start (the
            // annotate panel fills it), so nothing grows or is cut.
            XCTAssertTrue(lastLabel.isHittable, "the faces are cut off")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "mood-sheet-regular"
            shot.lifetime = .keepAlways
            add(shot)
        } else {
            XCTAssertTrue(grabber.exists, "a compact sheet shows the grabber")
        }
    }

    /// Log tab, picker, Measurement row: the sheet is up when its date picker is.
    private func openMeasurementSheet() {
        XCTAssertTrue(ShellNavigator.select(tab: .log, in: app), "the Log tab is missing")
        let row = app.descendants(matching: .any)["capture.picker.row.measurement"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the capture picker did not open")
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["measure-sheet.recordedAt.picker"].firstMatch.waitForExistence(timeout: 15),
            "the measurement sheet did not open"
        )
    }
}
