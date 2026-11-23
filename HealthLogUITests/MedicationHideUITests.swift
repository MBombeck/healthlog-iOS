import XCTest

/// **Hiding a medication from the list on this device.**
///
/// Long press on a card, „Ausblenden“: the card leaves the list and the undo
/// toast names it. The collapsed „Ausgeblendet“ section brings it back, and the
/// choice survives a relaunch. Every case starts by showing whatever an earlier
/// run left hidden, and ends with nothing hidden, so the suite repeats.
///
/// World: the hermetic boot of `K1LayoutUITests` (marketing medications plus the
/// sweep overlay), German, network-free.
@MainActor
final class MedicationHideUITests: XCTestCase {
    private static let lisinopril = "mkshot-med-lisinopril"
    private static let naproxen = "mkshot-med-naproxen"
    private static let trulicity = "mkshot-med-trulicity"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHideShowsUndoAndUnhideBringsTheCardBack() {
        let app = boot()
        openMedications(app)
        showEverythingHidden(app)

        let card = card(app, Self.naproxen)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Naproxen card missing")
        chooseFromCardMenu(app, card: card, item: "Ausblenden")

        let toast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Naproxen ausgeblendet")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 4), "no undo toast naming the medication")
        XCTAssertTrue(waitForDisappearance(of: card), "the hidden card is still in the list")

        let hiddenHeader = app.staticTexts["Ausgeblendet"]
        XCTAssertTrue(hiddenHeader.waitForExistence(timeout: 5), "no „Ausgeblendet\" section")
        expandHiddenSection(app)
        let unhide = app.buttons["medications.hidden.unhide.\(Self.naproxen)"]
        XCTAssertTrue(unhide.waitForExistence(timeout: 5), "no „Einblenden\" button for Naproxen")
        XCTAssertEqual(unhide.label, "Naproxen einblenden")
        scrollUntilHittable(app, unhide)
        unhide.tap()

        XCTAssertTrue(card.waitForExistence(timeout: 10), "the card did not come back")
        XCTAssertTrue(waitForDisappearance(of: hiddenHeader), "the empty „Ausgeblendet\" section stayed")
    }

    func testHiddenMedicationStaysHiddenAfterRelaunch() {
        let first = boot()
        openMedications(first)
        showEverythingHidden(first)
        let card = card(first, Self.naproxen)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Naproxen card missing")
        chooseFromCardMenu(first, card: card, item: "Ausblenden")
        XCTAssertTrue(waitForDisappearance(of: card), "the hidden card is still in the list")
        first.terminate()

        let app = boot()
        openMedications(app)
        XCTAssertTrue(self.card(app, Self.lisinopril).waitForExistence(timeout: 20), "the list did not load")
        XCTAssertTrue(app.staticTexts["Ausgeblendet"].waitForExistence(timeout: 5), "the selection was lost")
        XCTAssertFalse(self.card(app, Self.naproxen).exists, "Naproxen is back after the relaunch")

        showEverythingHidden(app)
        XCTAssertTrue(self.card(app, Self.naproxen).waitForExistence(timeout: 10), "cleanup did not show Naproxen")
    }

    /// The review screens: the card menu, then „Ausgeblendet“ open above
    /// „Archiviert“. `HL_M1_APPEARANCE=light` and `HL_M1_XXL=1` in the test
    /// runner's environment pick the light look and the largest text size.
    func testCaptureMenuAndSections() {
        let app = boot()
        openMedications(app)
        showEverythingHidden(app)

        let lisinopril = card(app, Self.lisinopril)
        XCTAssertTrue(lisinopril.waitForExistence(timeout: 20), "Lisinopril card missing")
        scrollUntilHittable(app, lisinopril)
        pressHeader(of: lisinopril)
        let hide = app.buttons["Ausblenden"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "no „Ausblenden\" in the card menu")
        XCTAssertTrue(app.buttons["Bearbeiten"].exists)
        XCTAssertTrue(app.buttons["Archivieren"].exists)
        attach(app, "a-kontextmenue")
        hide.tap()
        XCTAssertTrue(waitForDisappearance(of: lisinopril))

        // Archive one so both sections stand on the screen.
        let trulicity = card(app, Self.trulicity)
        scrollUntilHittable(app, trulicity)
        XCTAssertTrue(trulicity.waitForExistence(timeout: 10))
        chooseFromCardMenu(app, card: trulicity, item: "Archivieren")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Archivieren")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no archive confirmation")
        confirm.tap()
        let archivedHeader = app.staticTexts["Archiviert"]
        XCTAssertTrue(archivedHeader.waitForExistence(timeout: 10), "no „Archiviert\" section")

        expandHiddenSection(app)
        let unhide = app.buttons["medications.hidden.unhide.\(Self.lisinopril)"]
        XCTAssertTrue(unhide.waitForExistence(timeout: 5))
        scrollUntilHittable(app, archivedHeader)
        // Settle the toast and the scroll before the capture.
        Thread.sleep(forTimeInterval: 6)
        attach(app, "b-ausgeblendet-und-archiviert")

        // Leave the world as it was.
        let restore = app.buttons["medications.archived.restore.\(Self.trulicity)"]
        if !restore.exists { app.buttons["Liste aufklappen"].firstMatch.tap() }
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        scrollUntilHittable(app, restore)
        restore.tap()
        showEverythingHidden(app)
    }

    // MARK: - Helpers

    private func card(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["medications.card.\(id)"]
    }

    /// Long press on the card's head, clear of the Genommen button and its
    /// own menu.
    private func pressHeader(of card: XCUIElement) {
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.06)).press(forDuration: 1.2)
    }

    private func chooseFromCardMenu(_ app: XCUIApplication, card: XCUIElement, item: String) {
        scrollUntilHittable(app, card)
        pressHeader(of: card)
        let entry = app.buttons[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no „\(item)\" in the card menu")
        entry.tap()
        _ = waitForDisappearance(of: app.buttons["Bearbeiten"])
    }

    private func expandHiddenSection(_ app: XCUIApplication) {
        let header = app.staticTexts["Ausgeblendet"]
        scrollUntilHittable(app, header)
        // „Ausgeblendet“ stands above „Archiviert“, so its toggle is the first.
        let toggle = app.buttons["Liste aufklappen"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no toggle under „Ausgeblendet\"")
        scrollUntilHittable(app, toggle)
        toggle.tap()
    }

    /// Shows every medication an earlier run left hidden.
    private func showEverythingHidden(_ app: XCUIApplication) {
        // The cards sit in a lazy stack, so at the largest text size the later
        // ones are not in the tree yet; the section headers always are.
        let loaded = app.staticTexts["Aktive Medikamente"].waitForExistence(timeout: 30)
            || app.staticTexts["Ausgeblendet"].exists
        XCTAssertTrue(loaded, "the medication list did not load")
        let unhides = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "medications.hidden.unhide."))
        for _ in 0 ..< 8 {
            if unhides.firstMatch.exists {
                let next = app.buttons[unhides.element(boundBy: 0).identifier]
                scrollUntilHittable(app, next)
                next.tap()
                _ = waitForDisappearance(of: next)
            } else if app.staticTexts["Ausgeblendet"].exists {
                expandHiddenSection(app)
                _ = unhides.firstMatch.waitForExistence(timeout: 3)
            } else {
                break
            }
        }
        XCTAssertFalse(app.staticTexts["Ausgeblendet"].exists, "could not show every hidden medication")
        app.swipeDown()
        app.swipeDown()
    }

    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0 ..< 10 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        for _ in 0 ..< 10 where !(element.exists && element.isHittable) {
            app.swipeDown(velocity: .slow)
        }
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openMedications(_ app: XCUIApplication) {
        XCTAssertTrue(ShellNavigator.select(symbol: "pills.fill", in: app, timeout: 20), "Medications tab missing")
    }

    private func boot() -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        var look: [String] = []
        if env["HL_M1_APPEARANCE"] == "light" { look += HermeticAppearance.lightArguments }
        if env["HL_M1_XXL"] == "1" {
            look += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchHermeticAndWaitForDashboard(
            extraArguments: UITestLanguage.de.launchArguments + [
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ] + look,
            timeout: 120
        )
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap() }
        return app
    }
}
