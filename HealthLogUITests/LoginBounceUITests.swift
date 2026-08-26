import XCTest

/// **Phase 24 / plan 24-02 — D-24-01-A: the login lock-out.**
///
/// The operator, having signed out as a stopgap, could not sign back in. On the
/// passkey path the system sheet appeared, his passkey was accepted, the
/// HealthLog app icon was shown, and he was returned to the onboarding start
/// screen, unauthenticated. On the password path he landed back on the same
/// screen immediately. Both credential steps succeeded; the app never reached
/// the shell.
///
/// ## Why this suite is a UI test and not a unit test
///
/// Every part of the trap is view lifecycle:
///
/// - `RootPrivacyShieldPolicy.resolve` returns `.protected(.inactive)` on
///   `!sceneIsActive` **unconditionally on phase**, and `RootView.rootBody`
///   replaces the whole unprotected subtree with the shield. Its `.inactive`
///   face is a heart glyph over the word "HealthLog" — the app icon he saw.
/// - `OnboardingFlow` is therefore unmounted, and its `@State step` is
///   re-created at `OnboardingFlow.initialStep` on the way back in.
/// - The flow's only forward path out of `.authenticating` was
///   `.onChange(of: authStore.phase)`, and a phase that has already arrived
///   sends no further notification.
///
/// None of that is observable from a store: the store is doing exactly what it
/// is supposed to do, and does it correctly throughout. The only honest place to
/// ask "did the user get into the app?" is the app.
///
/// ## The one fidelity difference, stated rather than hidden
///
/// In Release `OnboardingFlow.initialStep` is `.welcome`, which is why the
/// operator lands on "Deine Gesundheit, dein Tempo". Under the DEBUG
/// `-uitest-auth-journey` seam it is `.auth`, because the ServerURL step runs a
/// live reachability probe the fixture protocol cannot stub. Both are the same
/// `@State` reset to the same constant; the DEBUG value is what makes the
/// operator's *second* attempt drivable in-process, since the sign-in door is
/// the surface the remounted flow reopens on.
///
/// ## Scene deactivation, honestly obtained
///
/// A passkey sheet and iOS's own "Passwort sichern?" prompt (D-09-16-D) are
/// presented by another process and resign the scene. A UI test cannot drive
/// either on demand — 11-03, 12-12 and 14-05 each tried. What it CAN do is
/// produce the same scene transition the same way the operating system does:
/// send the app to the background and bring it back. `RootPrivacyShieldPolicy`
/// reads one bit, `scenePhase == .active`, and does not care which sheet cleared
/// it.
final class LoginBounceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Constants

    /// The same seeded credentials `AuthJourneyUITest` uses. The fixture backend
    /// answers the login route with a session for them.
    private static let email = "hermetic@uitest.local"
    private static let password = "hunter2hunter2"

    /// The skippable post-authentication steps, in route order. Walking them is
    /// how a `returningLoginIncomplete` account reaches the shell.
    private static let setupTailSkips = [
        "onboarding.healthKit.skip",
        "onboarding.notifications.skip",
        "onboarding.aiSource.skip",
        "onboarding.anamnesis.skip",
        "onboarding.baselineProfile.skip"
    ]

    /// What the app settled on. Named rather than boolean so a failure says
    /// which of the three screens the user was actually looking at.
    private enum Outcome: String {
        /// The authenticated shell — the only acceptable answer.
        case shell
        /// The sign-in door, reopened over a session that already exists.
        case signInDoor
        /// The onboarding start screen — the Release symptom.
        case welcomeStep
        /// Neither, within the budget.
        case neither
    }

    // MARK: - 24-02-A — the bounce

    /// A sign-in that succeeds, a scene that deactivates and reactivates around
    /// it, and the shell as the assertion.
    ///
    /// The starting state is a real signed-out install driven through the real
    /// login form against the fixture backend — not a constructed phase. The
    /// precondition is asserted rather than assumed: the post-authentication
    /// route opens its first step, which is only reachable once
    /// `AuthStore.phase` is `.authenticating(user)` and the session is persisted.
    /// Everything after that is about whether the app can still get the user in.
    @MainActor
    func testASignInInterruptedByASceneDeactivationStillReachesTheShell() {
        let app = XCUIApplication()
        app.launchPhase8Onboarding(.returningLoginIncomplete)
        submitPasswordLogin(app)

        // The credential step succeeded: the flow left the door and opened the
        // first step of the post-authentication route.
        let firstSetupStep = app.buttons[Self.setupTailSkips[0]]
        XCTAssertTrue(
            firstSetupStep.waitForExistence(timeout: 40),
            "Precondition: the login must succeed and open the post-authentication route"
        )

        deactivateAndReactivateTheScene(app)

        let outcome = walkToTheShell(app, timeout: 60)
        print("login-bounce: 24-02-A settled on \(outcome.rawValue) after one scene deactivation")
        if outcome != .shell { attachFailureDiagnostics(app: app, label: "login-bounce-a-\(outcome.rawValue)") }
        XCTAssertEqual(
            outcome,
            .shell,
            "EXPECTED_RED: 24-02-A a scene deactivation across a successful sign-in returns the user to the sign-in door with a live session and no way forward"
        )
    }

    // MARK: - 24-02-B — the repeat attempt

    /// The half that makes the trap permanent rather than transient.
    ///
    /// After the bounce the operator signed in again — and a second login with
    /// the same account assigns an **equal** `AuthStore.Phase`
    /// (`acceptSession` → `admitAuthenticating`, with no pass through
    /// `.unauthenticated`; the attempt fence even requires the entry phase to be
    /// unchanged). An equal assignment publishes no change, so anything waiting
    /// for one waits forever.
    ///
    /// The case is written so that both worlds are meaningful. On the fixed tree
    /// the door is not offered a second time, because the app has already
    /// recovered; the second deactivation then measures the same claim from the
    /// other side, since across it **no phase transition exists at all**.
    @MainActor
    func testASecondSignInWithTheSameAccountAfterTheBounceStillReachesTheShell() {
        let app = XCUIApplication()
        app.launchPhase8Onboarding(.returningLoginIncomplete)
        submitPasswordLogin(app)

        let firstSetupStep = app.buttons[Self.setupTailSkips[0]]
        XCTAssertTrue(
            firstSetupStep.waitForExistence(timeout: 40),
            "Precondition: the login must succeed and open the post-authentication route"
        )

        deactivateAndReactivateTheScene(app)

        // The operator's second attempt, with the same account. Offered only on
        // a tree where the bounce happened at all.
        let signInDoor = app.buttons["onboarding.passwordLoginCTA"]
        let doorReopened = signInDoor.waitForExistence(timeout: 15)
        print("login-bounce: 24-02-B sign-in door reopened after the bounce = \(doorReopened)")
        if doorReopened { submitPasswordLogin(app) }

        // And a second deactivation, across which nothing about the phase can
        // have changed — the same information state a repeat login produces.
        deactivateAndReactivateTheScene(app)

        let outcome = walkToTheShell(app, timeout: 60)
        print("login-bounce: 24-02-B settled on \(outcome.rawValue) after the repeat attempt")
        if outcome != .shell { attachFailureDiagnostics(app: app, label: "login-bounce-b-\(outcome.rawValue)") }
        XCTAssertEqual(
            outcome,
            .shell,
            "EXPECTED_RED: 24-02-B a repeat sign-in with the same account assigns an equal phase, so no notification is published and the app never leaves the sign-in door"
        )
    }

    // MARK: - Helpers

    /// Background the app and bring it back — the same `scenePhase` transition a
    /// system credential sheet produces, obtained the one way a UI test can
    /// obtain it deterministically.
    ///
    /// The app is required to SURVIVE it. A terminated app would cold-launch,
    /// `AuthStore.bootstrap()` would resolve the persisted session straight to
    /// `.authenticated`, and the case would pass for the one reason 24-01
    /// already proved works — the force-quit workaround — while saying nothing
    /// about the defect.
    @MainActor
    private func deactivateAndReactivateTheScene(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        // `XCUIApplication.state` is a lagging snapshot, measured on this suite's
        // first run: it still read `.runningForeground` ten seconds after the
        // home press and `.runningBackground` fifteen seconds after the
        // reactivation. `wait(for:timeout:)` is the API that actually polls.
        //
        // Either background state is a resigned scene, and both are the SAME
        // process — which is the requirement here. A relaunch would re-run
        // `AuthStore.bootstrap()`, resolve the persisted session straight to
        // `.authenticated`, and pass for the one reason 24-01 already proved
        // works (the force-quit workaround) while saying nothing about this
        // defect. A terminated app satisfies neither wait, so it fails here.
        let resigned = app.wait(for: .runningBackground, timeout: 10)
            || app.wait(for: .runningBackgroundSuspended, timeout: 10)
        XCTAssertTrue(resigned, "The app never resigned the foreground as the same process")
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "The app never came back to the foreground"
        )
    }

    /// Enter the seeded credentials and sign in. Mirrors `AuthJourneyUITest`'s
    /// own helper; that file sits close enough to its 600-line ceiling that
    /// sharing it would mean moving something out of it first, and this suite is
    /// not allowed to touch it.
    @MainActor
    private func submitPasswordLogin(_ app: XCUIApplication) {
        // D-09-16-D. The second sign-in of 24-02-B runs after a first one, and
        // iOS's own "Passwort sichern?" prompt is standing over the re-composed
        // form by then — measured on this suite's third run, which printed the
        // tree: the app's auth step fully rendered underneath (`Schritt 3 von 8`)
        // and the OS sheet with its two buttons above it. Worth recording for
        // its own sake: the app's window is LIVE under that sheet, so on this
        // runtime the password prompt does not resign the scene.
        clearTheOSPasswordPromptIfSettled(app)

        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 25), "Auth step 'Sign in' CTA never appeared")

        // Hittability, not just existence. The second sign-in of 24-02-B happens
        // on a subtree that has just been re-composed after a reactivation, and
        // the first run of this suite measured the consequence: the field
        // existed and the tap was refused ("Failed to not hittable: TextField").
        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "Email field missing on the auth step")
        focus(emailField, in: app, named: "email")
        emailField.typeText(Self.email)

        let passwordField = app.secureTextFields.firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "Password field missing on the auth step")
        focus(passwordField, in: app, named: "password")
        passwordField.typeText(Self.password)
        passwordField.typeText("\n")

        if !waitUntilHittable(signIn) { app.swipeUp() }
        signIn.tap()
    }

    /// Put the caret in a field that has just been re-composed.
    ///
    /// `isHittable` is not required. On the second sign-in — the whole point of
    /// 24-02-B — the subtree was rebuilt milliseconds earlier and the first runs
    /// of this suite measured a field that existed at a stable frame and stayed
    /// unhittable for thirty seconds. A centre-of-element coordinate tap
    /// addresses the same pixels without consulting the hit-test snapshot, and
    /// the element tree is printed when hittability never arrives so a future
    /// reader sees what was standing over it rather than guessing.
    @MainActor
    private func focus(_ element: XCUIElement, in app: XCUIApplication, named what: String) {
        clearTheOSPasswordPromptIfSettled(app)
        if !waitUntilHittable(element, timeout: 10) {
            print("login-bounce: the \(what) field never reported hittable; element tree follows\n\(app.debugDescription)")
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Dismiss iOS's password prompt, but only once it has actually settled.
    ///
    /// `SystemSheetDismissal` refuses — by design — a sheet whose decline button
    /// is not hittable, because on the release gate that is a real finding. Here
    /// it is routinely just a sheet mid-animation, met by a loop that samples
    /// three times a second, and the refusal fired on the animation rather than
    /// on anything about the product. So the shape is read through the shipped
    /// predicate and the dismissal is only asked for when there is something
    /// steady to dismiss; anything that is NOT the measured password prompt is
    /// still never touched.
    @MainActor
    private func clearTheOSPasswordPromptIfSettled(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        guard sheet.exists,
              SystemSheetDismissal.looksLikeSystemPasswordPrompt(
                  buttonCount: sheet.buttons.count,
                  hasTextFields: sheet.textFields.firstMatch.exists,
                  hasSecureTextFields: sheet.secureTextFields.firstMatch.exists
              ),
              sheet.buttons.element(boundBy: 0).isHittable else { return }
        SystemSheetDismissal.dismissIfPresent(in: app)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(200_000)
        }
        return element.isHittable
    }

    /// Walk whatever the app offers until one of the three named screens
    /// settles.
    ///
    /// A `returningLoginIncomplete` account genuinely owes the setup tail, so
    /// reaching the shell means walking it — the skips are taken as they appear
    /// rather than in a fixed sequence, because the whole question here is which
    /// step the app decides to show. The sign-in door and the welcome step are
    /// possible ANSWERS, not preconditions, so neither is waited for: whichever
    /// screen arrives first is what the user is looking at.
    @MainActor
    private func walkToTheShell(_ app: XCUIApplication, timeout: TimeInterval) -> Outcome {
        let greeting = app.staticTexts["dashboard.greeting"]
        let signInDoor = app.buttons["onboarding.passwordLoginCTA"]
        let welcome = app.buttons["onboarding.welcome.cta"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // D-09-16-D — clear the OS password prompt before reading the
            // screen, so an app surface is never mistaken for absent because
            // something the app does not own is standing over it.
            clearTheOSPasswordPromptIfSettled(app)
            if greeting.exists { return .shell }
            if signInDoor.exists { return .signInDoor }
            if welcome.exists { return .welcomeStep }
            takeTheNextSetupStepIfOffered(app)
            usleep(300_000)
        }
        return .neither
    }

    /// Tap at most one offered skip per sweep, after clearing an OS-owned sheet
    /// that may be standing over it (D-09-16-D). One per sweep so the loop
    /// re-reads the screen between taps instead of firing at a step that has
    /// already left.
    @MainActor
    private func takeTheNextSetupStepIfOffered(_ app: XCUIApplication) {
        for identifier in Self.setupTailSkips {
            let step = app.buttons[identifier]
            guard step.exists else { continue }
            clearTheOSPasswordPromptIfSettled(app)
            if step.isHittable {
                step.tap()
            } else {
                // Same measured reason as `focus(_:in:named:)`: a subtree that
                // has just been re-composed can hold a stable frame and refuse
                // hit-testing. A skip is idempotent, so a coordinate tap that
                // lands early costs a sweep, never a wrong step.
                step.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
    }
}
