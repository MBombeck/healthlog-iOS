import XCTest

/// **The capture screens' delete questions, photographed.**
///
/// The medication detail's history deletes from its `⋯` menu and from a long
/// press, and the measurement list deletes several readings from the bottom
/// bar. All three ask first through the delete ladder; the walk shows each
/// question, answers it and shows the list after. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_26_deleteFlows() {
        boot(extra: ["-uitest-area-meds"])
        historyDeletes()
        bulkDelete()
    }

    private func historyDeletes() {
        tab("pills.fill")
        guard let card = probe("medications.card.mkshot-med-trulicity") else {
            note("Trulicity card missing")
            return
        }
        card.tap()
        settle(3)
        let menu = app.buttons["Eintrag bearbeiten oder löschen"].firstMatch
        for _ in 0 ..< 10 where !(menu.exists && menu.isHittable) {
            scrollDown()
        }
        let before = app.buttons.matching(identifier: "Eintrag bearbeiten oder löschen").count
        note("history menus before: \(before)")
        guard tap(menu, "history row menu") else { return }
        settle(1)
        guard tap(app.buttons["Löschen"].firstMatch, "menu delete") else { return }
        settle(1.5)
        questionShot("26-history-menu-question")
        answerDelete()
        settle(2.5)
        shot("26-history-menu-after")
        note("history menus after menu delete: \(app.buttons.matching(identifier: "Eintrag bearbeiten oder löschen").count)")

        // The long press on a row opens the same entries as a context menu.
        // A history row's own date ("26. Okt., 09:05"), not the hero's
        // weekday line.
        let row = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{1,2}\\. [^,]+, 09:05$")).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.press(forDuration: 1.2)
            settle(1.5)
            questionShot("26-history-context-menu")
            if tap(app.buttons["Löschen"].firstMatch, "context delete") {
                settle(1.5)
                questionShot("26-history-context-question")
                answerDelete()
                settle(2.5)
                shot("26-history-context-after")
                note("history menus after context delete: \(app.buttons.matching(identifier: "Eintrag bearbeiten oder löschen").count)")
            }
        } else {
            note("no history row to long-press")
        }
        goBack()
        settle(1)
    }

    private func bulkDelete() {
        tab("ellipsis")
        scrollUpToTop()
        guard let measurements = probe("more.row.measurements") else {
            note("More row measurements missing")
            return
        }
        measurements.tap()
        settle(3)
        answerHealthAccess()
        guard tap(element("measurements.picker.row.weight"), "weight row") else { return }
        settle(3)
        guard tap(app.buttons["Auswählen"].firstMatch, "select") else { return }
        settle(1.5)
        let readings = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' kg'"))
        let before = readings.count
        for index in 0 ..< 2 where readings.count > index {
            readings.element(boundBy: index).tap()
            settle(0.5)
        }
        shot("26-bulk-selected")
        guard tap(element("measurements.list.bulkDelete"), "bulk delete") else { return }
        settle(1.5)
        questionShot("26-bulk-question")
        answerDelete()
        settle(3)
        shot("26-bulk-after")
        note("weight readings before \(before), after \(readings.count)")
    }

    /// The picture of an open question; `shot` would answer it.
    private func questionShot(_ name: String) {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    /// The question's own delete button; it stands twice in the tree.
    private func answerDelete() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            note("question: \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
            alert.buttons["Löschen"].firstMatch.tap()
            return
        }
        let sheetButton = app.sheets.buttons["Löschen"].firstMatch
        if sheetButton.waitForExistence(timeout: 2) {
            note("question as a sheet")
            sheetButton.tap()
            return
        }
        note("no question appeared")
    }
}
