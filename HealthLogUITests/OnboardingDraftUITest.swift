import XCTest

/// #153 (public #27, jimmy-ck) — leaving the app in the middle of setup
/// must not send the user back to the start.
///
/// The privacy shield replaces the whole window content as soon as the scene
/// stops being active, so everything a step kept in its own view state was
/// gone when the user came back from copying a header value out of a password
/// manager. The step and what was typed now live in the container's in-memory
/// draft; this test leaves the app twice (home screen, then only the
/// Notification Center pulled over it) and checks both.
final class OnboardingDraftUITest: XCTestCase {
    private static let address = "health.example.com"
    private static let clientID = "id-153"
    private static let clientSecret = "secret-153"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testServerStepSurvivesLeavingTheApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-bootstrap"]
        app.launch()
        fillServerStep(app)

        // 1. Home screen and back: the scene goes to the background.
        XCUIDevice.shared.press(.home)
        let resigned = app.wait(for: .runningBackground, timeout: 10)
            || app.wait(for: .runningBackgroundSuspended, timeout: 10)
        XCTAssertTrue(resigned, "The app never left the foreground")
        app.activate()
        assertServerStepKept(app, after: "home")

        // 2. Only `.inactive`: Notification Center pulled over the app. The
        //    shield shows, the scene never reaches the background.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        XCTAssertTrue(
            app.otherElements["privacyCover"].waitForExistence(timeout: 5),
            "Pulling Notification Center over the app should make the scene inactive"
        )
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        assertServerStepKept(app, after: "inactive")
    }

    /// (g) — the server step with the access headers unfolded, de/en, dark and
    /// light. Only runs when `TEST_RUNNER_HL_SWEEP_OUT` names a directory, like
    /// the QA sweep.
    @MainActor
    func testServerStepShots() throws {
        let out = ProcessInfo.processInfo.environment["HL_SWEEP_OUT"] ?? ""
        try XCTSkipIf(out.isEmpty, "HL_SWEEP_OUT not set — shots only on request")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        for language in ["de", "en"] {
            for appearance in ["dark", "light"] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-uitest-skip-bootstrap",
                    "-AppleLanguages", "(\(language))",
                    "-AppleLocale", language == "de" ? "de_DE" : "en_US",
                    "-hl.settings.appearance", appearance,
                    "-hl.settings.darkDefault.reasserted.v1", "YES"
                ]
                app.launch()
                let cta = app.buttons["onboarding.welcome.cta"]
                XCTAssertTrue(cta.waitForExistence(timeout: 10))
                cta.tap()
                XCTAssertTrue(app.textFields["onboarding.serverCustom"].waitForExistence(timeout: 10))
                Thread.sleep(forTimeInterval: 1)
                save(XCUIScreen.main.screenshot(), "\(out)/server-\(language)-\(appearance)-folded.png")
                fillServerStep(app, launched: true)
                // The keyboard would cover the editor; the shot is about the editor.
                app.typeText("\n")
                app.scrollViews.firstMatch.swipeUp()
                Thread.sleep(forTimeInterval: 1)
                save(XCUIScreen.main.screenshot(), "\(out)/server-\(language)-\(appearance)-headers.png")
                app.terminate()
            }
        }
    }

    // MARK: - Steps

    @MainActor
    private func fillServerStep(_ app: XCUIApplication, launched: Bool = false) {
        if !launched {
            let cta = app.buttons["onboarding.welcome.cta"]
            XCTAssertTrue(cta.waitForExistence(timeout: 10), "Welcome CTA missing")
            cta.tap()
        }
        let urlField = app.textFields["onboarding.serverCustom"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "Server step missing")
        urlField.tap()
        urlField.typeText(Self.address)

        let advanced = app.buttons["onboarding.serverURLAccessHeaders"]
        advanced.tap()
        let cloudflare = app.buttons["serverAccessHeaders.preset.cloudflare"]
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 5), "Access headers did not unfold")
        cloudflare.tap()
        let values = app.secureTextFields.matching(identifier: "serverAccessHeaders.value")
        XCTAssertEqual(values.count, 2)
        values.element(boundBy: 0).tap()
        values.element(boundBy: 0).typeText(Self.clientID)
        values.element(boundBy: 1).tap()
        values.element(boundBy: 1).typeText(Self.clientSecret)
    }

    @MainActor
    private func assertServerStepKept(_ app: XCUIApplication, after leaving: String) {
        let urlField = app.textFields["onboarding.serverCustom"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "After \(leaving): not on the server step any more")
        XCTAssertEqual(urlField.value as? String, Self.address, "After \(leaving): the address was lost")
        let names = app.textFields.matching(identifier: "serverAccessHeaders.name")
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 5), "After \(leaving): the headers folded away")
        XCTAssertEqual(names.count, 2, "After \(leaving): the header rows were lost")
        XCTAssertEqual(names.element(boundBy: 0).value as? String, "CF-Access-Client-Id")

        // The values stay masked; a secure field reports one bullet per
        // character, which is enough to tell a kept value from a lost one.
        let values = app.secureTextFields.matching(identifier: "serverAccessHeaders.value")
        XCTAssertEqual(values.count, 2, "After \(leaving): the value fields were lost")
        XCTAssertEqual((values.element(boundBy: 0).value as? String)?.count, Self.clientID.count, "After \(leaving): a value was lost")
        XCTAssertEqual((values.element(boundBy: 1).value as? String)?.count, Self.clientSecret.count, "After \(leaving): a value was lost")
    }

    private func save(_ screenshot: XCUIScreenshot, _ path: String) {
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
