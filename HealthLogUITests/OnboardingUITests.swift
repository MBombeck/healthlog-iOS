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
        // Server-connect is mandatory: after the welcome CTA we land DIRECTLY
        // on the server-URL step — the only path forward is connecting a
        // server.
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

        // Capture the server-mandatory onboarding for the audit record.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "onboarding-server-mandatory"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A server behind Cloudflare Access or Pangolin rejects the
    /// address check unless its headers are set, so they unfold under
    /// "Advanced" on the server step, before the first request.
    @MainActor
    func testAccessHeadersUnfoldOnServerStep() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-skip-bootstrap"]
        app.launch()

        let cta = app.buttons["onboarding.welcome.cta"]
        XCTAssertTrue(cta.waitForExistence(timeout: 5), "Welcome CTA missing")
        cta.tap()

        let advanced = app.buttons["onboarding.serverURLAccessHeaders"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 6), "Advanced link missing on the server step")
        let cloudflare = app.buttons["serverAccessHeaders.preset.cloudflare"]
        XCTAssertFalse(cloudflare.exists, "Access headers must stay folded until asked for")
        let folded = XCTAttachment(screenshot: app.screenshot())
        folded.name = "onboarding-server-advanced-folded"
        folded.lifetime = .keepAlways
        add(folded)

        advanced.tap()
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 5), "Access headers did not unfold")
        cloudflare.tap()
        XCTAssertEqual(app.textFields.matching(identifier: "serverAccessHeaders.name").count, 2)

        let unfolded = XCTAttachment(screenshot: app.screenshot())
        unfolded.name = "onboarding-server-advanced-cloudflare"
        unfolded.lifetime = .keepAlways
        add(unfolded)
    }
}
