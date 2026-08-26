import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeScreenShowsCTA() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-bootstrap"]
        app.launch()

        let cta = app.buttons["onboarding.welcome.cta"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "Welcome CTA missing")
    }

    @MainActor
    func testServerURLStepIsReachedFromWelcome() {
        // v0.15 — server-connect is mandatory
        // (`FeatureFlags.standaloneModeAvailable == false`): after the welcome
        // CTA we land DIRECTLY on the server-URL step. The `ModeSelectionStep`
        // fork is skipped, so neither the server-mode card nor the standalone
        // card is presented — the only path forward is connecting a server.
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-bootstrap"]
        app.launch()

        let cta = app.buttons["onboarding.welcome.cta"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "Welcome CTA missing")
        cta.tap()

        let urlField = app.textFields["onboarding.serverCustom"]
        XCTAssertTrue(
            urlField.waitForExistence(timeout: 6),
            "Server-URL field should be reached directly after Welcome"
        )

        // No standalone door anywhere: the mode-selection fork must not appear.
        XCTAssertFalse(
            app.buttons["onboarding.modeStandalone"].exists,
            "Standalone (use-without-a-server) option must be hidden"
        )

        // Capture the server-mandatory onboarding for the audit record.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "onboarding-server-mandatory"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
