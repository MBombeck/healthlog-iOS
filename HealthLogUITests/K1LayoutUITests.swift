import XCTest

/// **K1 (1.1.0) — the two layout findings from the H2 sweep that a query can
/// measure.**
///
/// - The error banner makes room: on the medication detail the sweep fixture's
///   undecodable `{}` raises the banner over the cached detail, which is the
///   same state a real offline refresh produces. Nothing the screen shows may
///   sit under it.
/// - The medication card's action pair: side by side at the default size on a
///   large device, stacked at an accessibility size, where side by side broke
///   „Ge-nom-men" over three lines.
///
/// World: the same hermetic boot as `QASweepScreenshotsTest` (marketing
/// medications plus the sweep overlay), German, network-free.
@MainActor
final class K1LayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testErrorBannerDoesNotCoverTheMedicationDetail() {
        let app = boot()
        openMedications(app)
        let card = app.descendants(matching: .any)["medications.card.mkshot-med-trulicity"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Trulicity card missing")
        card.tap()

        let banner = app.descendants(matching: .any)["hl.errorBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "the fixture no longer raises the detail error banner")
        // Let the slide-in finish before measuring.
        Thread.sleep(forTimeInterval: 1.5)
        let bannerFrame = banner.frame
        let navBottom = app.navigationBars.firstMatch.frame.maxY
        // The banner's own message and retry label surface as texts too; they
        // are the banner, not what it covers.
        let message = (banner.value as? String) ?? ""
        let own: Set<String> = [message, "Erneut versuchen", "Try again"]

        let covered = app.staticTexts.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 1 && !own.contains($0.label) }
            .filter { $0.frame.minY >= navBottom - 1 && $0.frame.intersects(bannerFrame.insetBy(dx: 0, dy: 1)) }
            .map { "\($0.label.count) chars @\($0.frame)" }
        XCTAssertTrue(
            covered.isEmpty,
            "text under the error banner \(bannerFrame): \(covered)"
        )
    }

    func testMedicationActionsShareARowAtTheDefaultSize() {
        let app = boot()
        openMedications(app)
        let (taken, skipped) = firstActionPair(app)
        XCTAssertEqual(taken.frame.midY, skipped.frame.midY, accuracy: 1, "default size: the pair left its row")
    }

    func testMedicationActionsStackAtAnAccessibilitySize() {
        let app = boot(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        openMedications(app)
        let (taken, skipped) = firstActionPair(app)
        XCTAssertLessThanOrEqual(
            taken.frame.maxY,
            skipped.frame.minY + 1,
            "AX-XXL: „Genommen\" \(taken.frame) and „Übersprungen\" \(skipped.frame) still share a row"
        )
    }

    // MARK: - Helpers

    private func firstActionPair(_ app: XCUIApplication) -> (XCUIElement, XCUIElement) {
        let taken = app.buttons.matching(NSPredicate(format: "label == %@", "Genommen")).firstMatch
        let skipped = app.buttons.matching(NSPredicate(format: "label == %@", "Übersprungen")).firstMatch
        XCTAssertTrue(taken.waitForExistence(timeout: 20), "no „Genommen\" action on the medication list")
        XCTAssertTrue(skipped.waitForExistence(timeout: 5), "no „Übersprungen\" action on the medication list")
        return (taken, skipped)
    }

    private func openMedications(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons.containing(.image, identifier: "pills.fill").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Medications tab missing")
        tab.tap()
    }

    private func boot(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-AppleLanguages", "(de)",
                "-AppleLocale", "de_DE",
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ] + extra,
            timeout: 120
        )
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap() }
        return app
    }
}
