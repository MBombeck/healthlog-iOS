import XCTest

/// **LIFE (1.5.0, #132, Server #1334)** — "When you stopped" is picked as
/// a month and year, saved, and still there after leaving the screen.
///
/// On the web the field was a text box that swallowed every keystroke short of
/// a whole `YYYY-MM` (Server #1334). In the app there is nothing to type: the
/// row unfolds the system month-and-year wheel. The fixture server
/// (`-uitest-life`) keeps the written answers, so reopening the screen reads
/// them back from the read route.
final class LifeCircumstancesUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFormerSmokerQuitMonthIsSavedAndReloaded() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchHermeticAndWaitForDashboard(extraArguments: ["-uitest-life"], timeout: 120)
        openLifeCircumstances(app)
        openTobacco(app)

        // Smoking status: Former smoker. Only then is the quit month asked.
        let quit = app.phase8Element("life.tobacco.quitMonth")
        XCTAssertFalse(quit.exists, "The quit month must not be asked before the status says 'former'")
        let status = app.phase8Element("life.tobacco.status")
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Smoking status picker missing")
        status.tap()
        let former = app.buttons["Former smoker"]
        XCTAssertTrue(former.waitForExistence(timeout: 5), "Status menu did not open")
        former.tap()

        let quitRow = app.scrollToPhase8("life.tobacco.quitMonth")
        quitRow.tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 5), "Month and year wheel did not unfold")
        XCTAssertEqual(wheels.count, 2, "A month and a year, nothing finer")
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "March")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "2019")
        XCTAssertEqual(quitRow.value as? String, "March 2019")
        // Fold the wheel away again, so a swipe scrolls the page instead of
        // turning a wheel.
        quitRow.tap()
        XCTAssertTrue(wheels.firstMatch.waitForNonExistence(timeout: 5), "Wheel did not fold away")
        XCTAssertEqual(quitRow.value as? String, "March 2019", "Folding must keep the chosen month")

        let save = app.scrollToPhase8("life.section.tobacco.save")
        XCTAssertTrue(save.isEnabled, "Save should be enabled with a changed section")
        save.tap()
        // Saved: the section reloads and no change is left to save.
        let saved = NSPredicate(format: "isEnabled == false")
        expectation(for: saved, evaluatedWith: save)
        waitForExpectations(timeout: 15)

        // Leave and come back: a new screen reads the answer from the server.
        app.navigationBars.buttons["BackButton"].tap()
        openLifeCircumstances(app, fromAboutMe: true)
        openTobacco(app)
        let reloaded = app.scrollToPhase8("life.tobacco.quitMonth")
        XCTAssertEqual(reloaded.value as? String, "March 2019", "The quit month did not come back from the server")
    }

    /// Screens for the report, de/en, light/dark, and the accessibility size.
    /// Only runs when `HL_SWEEP_OUT` names a directory.
    @MainActor
    func testLifeCircumstancesShots() throws {
        let out = ProcessInfo.processInfo.environment["HL_SWEEP_OUT"] ?? ""
        try XCTSkipIf(out.isEmpty, "HL_SWEEP_OUT not set — shots only on request")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        continueAfterFailure = true
        let variants = ["de light", "de dark", "en light", "en dark", "de light xxl"]
        for variant in variants {
            let parts = variant.split(separator: " ").map(String.init)
            let (language, appearance, xxl) = (parts[0], parts[1], parts.count > 2)
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(language))",
                "-AppleLocale", language == "de" ? "de_DE" : "en_US",
                "-hl.settings.appearance", appearance,
                "-hl.settings.darkDefault.reasserted.v1", "YES"
            ] + (xxl ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            app.launchHermeticAndWaitForDashboard(extraArguments: ["-uitest-life"], timeout: 120)
            let name = "\(language)-\(appearance)\(xxl ? "-xxl" : "")"
            openLifeCircumstances(app)
            shot("\(out)/life-closed-\(name).png")
            openTobacco(app)
            app.phase8Element("life.tobacco.status").tap()
            let former = app.buttons[language == "de" ? "Früher geraucht" : "Former smoker"]
            if former.waitForExistence(timeout: 5) { former.tap() }
            let quit = app.scrollToPhase8("life.tobacco.quitMonth")
            quit.tap()
            Thread.sleep(forTimeInterval: 1)
            shot("\(out)/life-tobacco-\(name).png")
            quit.tap()
            app.scrollToPhase8("life.section.tobacco.save")
            shot("\(out)/life-tobacco-save-\(name).png")
            let advanced = app.scrollToPhase8("life.section.tobacco.advanced")
            advanced.tap()
            Thread.sleep(forTimeInterval: 0.5)
            app.swipeUp(velocity: .slow)
            shot("\(out)/life-tobacco-advanced-\(name).png")
            app.scrollToPhase8("life.screening.aaa_ultrasound", swipes: 12)
            shot("\(out)/life-screening-\(name).png")
            app.terminate()
        }
    }

    // MARK: - Steps

    @MainActor
    private func openLifeCircumstances(_ app: XCUIApplication, fromAboutMe: Bool = false) {
        if !fromAboutMe {
            let more = app.phase8Tab("ellipsis")
            XCTAssertTrue(more.waitForExistence(timeout: 10), "More tab missing")
            more.tap()
            let aboutMe = app.phase8Element("more.row.about_me")
            XCTAssertTrue(aboutMe.waitForExistence(timeout: 10), "About me row missing")
            aboutMe.tap()
        }
        let row = app.scrollToPhase8("aboutMe.row.lifeCircumstances")
        XCTAssertTrue(row.exists, "Life circumstances row missing under About me")
        row.tap()
        XCTAssertTrue(
            app.phase8Element("life.section.tobacco.header").waitForExistence(timeout: 15),
            "Life circumstances did not load"
        )
    }

    @MainActor
    private func openTobacco(_ app: XCUIApplication) {
        app.phase8Element("life.section.tobacco.header").tap()
    }

    @MainActor
    private func shot(_ path: String) {
        Thread.sleep(forTimeInterval: 0.8)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
