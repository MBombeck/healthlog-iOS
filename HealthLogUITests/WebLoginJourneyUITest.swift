import XCTest

/// **13-04 — the coverage gap that let K7 ship.**
///
/// The web-handoff login leg had unit tests against a stubbed authenticator and
/// nothing else: no UI test and no device-UAT row anywhere for
/// `onboarding.webLoginCTA`. So on build 266 a brand-new user's only visible way
/// in ended on a browser error page, and every automated gate in the repository
/// was green while it did.
///
/// This class closes the class of gap, not only the instance. It walks the leg
/// end to end **in the app**: the CTA appears where a self-hosted instance
/// serves the contract, a handoff that dead-ends returns the user to the sign-in
/// step with a stated error and a usable password form, that password form
/// actually signs them in, and the fallback link reveals a form that was closed.
///
/// **What is stubbed, and what is not.** `ASWebAuthenticationSession` is
/// presented out of process; a UI test cannot drive it, and one that tried would
/// be measuring Safari. So the *terminal outcome* of the sheet is stubbed
/// (`-uitest-weblogin-outcome`, DEBUG-only — see
/// `HermeticUITestSupport.WebLoginOutcome`), which is precisely the boundary
/// `AuthStore` already takes as its input. Everything downstream is the
/// production code: the dead-end classification, the fenced error, the password
/// fallback, the single-door session admission.
///
/// **What this therefore does NOT prove**, stated here rather than implied: that
/// a real browser against a real server completes the handoff. That is
/// `P13-AUTH-01` in `DEVICE-UAT.jsonl`, it needs hardware, and its success path
/// additionally needs the server fix to healthlog-iOS#96.
final class WebLoginJourneyUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private static let email = "hermetic@uitest.local"
    private static let password = "hunter2hunter2"

    /// Launch onto the onboarding auth step with the fixture backend live and,
    /// optionally, a canned web-handoff outcome installed.
    @MainActor
    private func launch(
        webLoginOutcome: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-auth-journey",
            "-uitest-disable-biometric-lock",
            // The fixture server serves the web-handoff contract only for this
            // class. `AuthJourneyUITest`'s world stays a server that does not,
            // which is the world it has always asserted against.
            "-uitest-weblogin"
        ] + extraArguments
        if let webLoginOutcome {
            app.launchArguments += ["-uitest-weblogin-outcome", webLoginOutcome]
        }
        app.launch()
        return app
    }

    /// The CTA is what the whole plan is about, so its absence is reported with
    /// the element tree rather than as a bare timeout.
    @MainActor
    private func awaitWebLoginCTA(_ app: XCUIApplication) -> XCUIElement {
        let cta = app.buttons["onboarding.webLoginCTA"]
        let appeared = cta.waitForExistence(timeout: 30)
        if !appeared { attachFailureDiagnostics(app: app, label: "weblogin-cta-missing") }
        XCTAssertTrue(
            appeared,
            "The web-handoff CTA never appeared on a self-hosted instance that serves the contract"
        )
        return cta
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(200_000)
        }
        return element.isHittable
    }

    @MainActor
    private func submitPasswordLogin(_ app: XCUIApplication) {
        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 25), "The password form's Sign in CTA never appeared")

        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "Email field missing on the auth step")
        emailField.tap()
        emailField.typeText(Self.email)

        let passwordField = app.secureTextFields.firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field missing on the auth step")
        passwordField.tap()
        passwordField.typeText(Self.password)
        passwordField.typeText("\n")

        if !waitUntilHittable(signIn) { app.swipeUp() }
        signIn.tap()
    }

    // MARK: - 1) the CTA exists at all

    /// A self-hosted instance whose login route answers gets the browser CTA,
    /// and — the K5 half — the password form is NOT already open behind it. If
    /// it were, the fallback link below would have nothing to reveal, which is
    /// exactly the state build 266 shipped.
    @MainActor
    func testWebLoginCTAIsOfferedAndTheFormStartsClosed() {
        let app = launch()
        let cta = awaitWebLoginCTA(app)

        XCTAssertTrue(cta.isHittable, "The web-handoff CTA is on screen but cannot be tapped")
        XCTAssertTrue(
            app.buttons["onboarding.webLoginFallback"].waitForExistence(timeout: 10),
            "The password fallback link must be offered alongside the CTA"
        )
        XCTAssertFalse(
            app.buttons["onboarding.passwordLoginCTA"].exists,
            "The password form must start closed while the browser CTA is the primary door"
        )
    }

    // MARK: - 2) the fallback link acts

    /// The control that was observably dead on the shipped build: tapping it
    /// must open a form that was closed a moment earlier.
    @MainActor
    func testFallbackLinkRevealsThePasswordForm() {
        let app = launch()
        _ = awaitWebLoginCTA(app)

        let fallback = app.buttons["onboarding.webLoginFallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), "The password fallback link never appeared")
        XCTAssertFalse(app.buttons["onboarding.passwordLoginCTA"].exists, "The form was already open before the tap")

        if !waitUntilHittable(fallback) { app.swipeUp() }
        fallback.tap()

        let revealed = app.buttons["onboarding.passwordLoginCTA"].waitForExistence(timeout: 10)
        if !revealed { attachFailureDiagnostics(app: app, label: "fallback-revealed-nothing") }
        XCTAssertTrue(revealed, "The fallback link did not reveal the password form")
    }

    // MARK: - 3) the dead end has a way out, and the way out works

    /// The whole of K7's client half in one walk: the handoff comes back having
    /// landed on a non-routable host, the app states that instead of leaving the
    /// user on a browser error page, the password form is already open behind
    /// the banner, and signing in with it actually reaches the shell.
    @MainActor
    func testDeadEndedHandoffFallsBackToAWorkingPasswordLogin() {
        // `returningLoginIncomplete` is the same scenario `AuthJourneyUITest`
        // uses for its password walk: it makes `/api/auth/me` say the optional
        // setup is genuinely outstanding, so the post-authentication route has a
        // deterministic landmark on the other side of the login instead of
        // depending on whether the shell has finished hydrating.
        let app = launch(
            webLoginOutcome: "dead-end",
            extraArguments: ["-uitest-phase8", "returningLoginIncomplete"]
        )
        let cta = awaitWebLoginCTA(app)
        if !waitUntilHittable(cta) { app.swipeUp() }
        cta.tap()

        let banner = app.staticTexts["onboarding.auth.errorBanner"]
        let stated = banner.waitForExistence(timeout: 20)
        if !stated { attachFailureDiagnostics(app: app, label: "deadend-no-error-stated") }
        XCTAssertTrue(stated, "A dead-ended handoff must state what happened rather than fail silently")

        let form = app.buttons["onboarding.passwordLoginCTA"]
        let opened = form.waitForExistence(timeout: 20)
        if !opened { attachFailureDiagnostics(app: app, label: "deadend-no-way-back") }
        XCTAssertTrue(opened, "A dead-ended handoff must leave the password form open — the way back")

        // And the way back is a way IN, not just a visible control.
        submitPasswordLogin(app)
        let skipHealthKit = app.buttons["onboarding.healthKit.skip"]
        let signedIn = skipHealthKit.waitForExistence(timeout: 30)
        if !signedIn { attachFailureDiagnostics(app: app, label: "deadend-fallback-login-failed") }
        XCTAssertTrue(signedIn, "The password fallback did not sign the user in after the dead end")
    }
}
