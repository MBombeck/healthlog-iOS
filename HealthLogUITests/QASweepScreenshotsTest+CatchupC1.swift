import XCTest

/// **#191 QoL — the capture sheet, photographed.**
///
/// The Log tab's "Messung" opens the sheet over the sweep's readings (all
/// typed by hand): the kinds logged recently as rows with their last value,
/// then Weight with a value far from the last one (the hint under the field),
/// then the glucose form with its context default, and finally "Speichern und
/// weiter" with the receipt and Undo standing in the sheet
/// (`-uitest-capture-receipt` answers the write). Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_c1_captureAssist() {
        boot(extra: [CaptureArguments.receipt])
        guard tapLogTab() else { return }
        settle(2)
        guard tap(element("capture.picker.row.measurement"), "capture row measurement") else { return }
        settle(2.5)
        shot("c1-measure-recent-rows")

        if tap(element("measure-sheet.recent-row.weight"), "recent row weight", timeout: 4) {
            settle(1)
        }
        guard let field = scalarField() else {
            note("c1: weight field not found")
            return
        }
        field.tap()
        field.typeText("8")
        settle(1)
        shot("c1-measure-last-value-deviates")

        clear(field)
        field.typeText("72")
        settle(1)
        if let saveAndNext = aboveKeyboard("measure-sheet.save-and-next") {
            saveAndNext.tap()
            settle(2.5)
            shot("c1-measure-receipt")
        } else {
            note("c1: save and next not found")
        }

        if tap(element("measure-sheet.recent-row.glucose"), "recent row glucose", timeout: 4) {
            settle(1)
            _ = aboveKeyboard("measure-sheet.glucose-context.picker")
            shot("c1-measure-glucose-context")
        }
    }

    private enum CaptureArguments {
        static let receipt = "-uitest-capture-receipt"
    }

    /// The value field of the scalar kinds.
    private func scalarField() -> XCUIElement? {
        let tagged = app.textFields["measure-sheet.scalar.field"].firstMatch
        if tagged.waitForExistence(timeout: 4) { return tagged }
        let any = app.textFields.firstMatch
        return any.exists ? any : nil
    }

    /// Drags the sheet's content above the keyboard (the shared `probe`
    /// starts its drag on the keyboard, where nothing scrolls) until the
    /// element is hittable.
    private func aboveKeyboard(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        let window = app.windows.firstMatch
        for _ in 0 ..< 6 {
            if target.exists, target.isHittable { return target }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
            settle(1.2)
        }
        return target.exists && target.isHittable ? target : nil
    }

    private func clear(_ field: XCUIElement) {
        let text = field.value as? String ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(text.count, 4)))
    }
}
