import XCTest

/// **H3 — auth-journey coverage (audit-v0162).**
///
/// The nine existing `HealthLogUITests` all boot pre-authenticated via
/// `-uitest-hermetic`, so login / MFA / logout had ZERO end-to-end coverage and
/// the v0158 flagship `MfaChallengeSheet` had none at any level. This suite
/// drives the REAL auth journey against the fixture-stubbed backend:
///
/// - **Password login → shell** (a non-MFA account),
/// - **MFA challenge sheet** appearing on an MFA account, its **wrong-code
///   retry** (sheet stays with an inline error) vs **dead-ticket eject** (back
///   to the password form) states, and a **correct code → shell**,
/// - **Logout** returning to the onboarding welcome screen.
///
/// The seam is the existing hermetic mechanism, extended (DEBUG-only) with a new
/// `-uitest-auth-journey` boot that lands on the onboarding **auth step** with
/// the fixture backend live but NO token (see `HermeticUITestSupport` +
/// `HermeticFixtures` + `OnboardingFlow.initialStep`). Login / MFA responses are
/// steered by `-uitest-mfa-challenge`, `-uitest-mfa-verify-wrong`, and
/// `-uitest-mfa-verify-dead`.
///
/// **Boundary:** the ServerURL onboarding step runs a live reachability probe
/// (`ServerReachabilityProbe`) that the fixture `URLProtocol` cannot stub (it is
/// scoped to the API sessions, not the ephemeral probe session), so — exactly as
/// with the authenticated hermetic boot — this suite opens on the auth step
/// rather than walking Welcome → ServerURL first. The post-auth permission tail
/// (HealthKit / Notifications / …) is walked via its skip affordances to reach
/// the authenticated shell.
final class AuthJourneyUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private static let email = "hermetic@uitest.local"
    private static let password = "hunter2hunter2"
    /// `LogoutConfirmation.confirmButtonIdentifier`, spelled out because a UI
    /// test runs out of process and cannot import the app target. It is the
    /// identifier the destructive dialog action carries, and 08-09 measured
    /// that identifiers *do* propagate onto `confirmationDialog` actions.
    private static let logoutConfirmIdentifier = "logout.confirm.signOut"

    /// Launch onto the onboarding auth step with the fixture backend live.
    @MainActor
    private func launchAuthJourney(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-auth-journey",
            "-uitest-disable-biometric-lock"
        ] + extraArguments
        app.launch()
        return app
    }

    /// Enter the seeded credentials and tap Sign in on the auth step.
    @MainActor
    private func submitPasswordLogin(_ app: XCUIApplication) {
        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 25), "Auth step 'Sign in' CTA never appeared")

        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "Email field missing on the auth step")
        emailField.tap()
        emailField.typeText(Self.email)

        let passwordField = app.secureTextFields.firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field missing on the auth step")
        passwordField.tap()
        passwordField.typeText(Self.password)

        // Keyboard down before submitting. NOTE: this alone does NOT clear the
        // empty full-screen `Window` the accessibility tree carries above the
        // main one — that was measured; see the quarantine note on
        // ``testPasswordLoginReachesShell``.
        passwordField.typeText("\n")

        // Belt and braces for short screens where the CTA genuinely sits below
        // the fold; with the keyboard gone this should no longer trigger.
        if !waitUntilHittable(signIn) { app.swipeUp() }
        signIn.tap()
    }

    /// Walk the skippable post-auth onboarding tail to the authenticated shell,
    /// then assert we crossed into the shell by keying off the tab bar's Home
    /// button — a locale-independent landmark that mounts the instant
    /// `OnboardingFlow` hands off to `AuthenticatedShell`, ahead of the Dashboard
    /// content hydrating. The greeting is then asserted as a secondary "content
    /// rendered" signal (deterministic under the hermetic fixtures).
    @MainActor
    private func skipOnboardingTailToDashboard(_ app: XCUIApplication) {
        let homeTab = tabBarButton(app, symbol: "house.fill")
        tapRequiredOnboardingStep(
            app.buttons["onboarding.healthKit.skip"],
            next: app.buttons["onboarding.notifications.skip"],
            timeout: 25,
            app: app
        )
        tapRequiredOnboardingStep(
            app.buttons["onboarding.notifications.skip"],
            next: app.buttons["onboarding.aiSource.skip"],
            timeout: 15,
            app: app
        )
        tapRequiredOnboardingStep(
            app.buttons["onboarding.aiSource.skip"],
            next: app.buttons["onboarding.anamnesis.skip"],
            timeout: 15,
            app: app
        )
        tapRequiredOnboardingStep(
            app.buttons["onboarding.anamnesis.skip"],
            next: app.buttons["onboarding.baselineProfile.skip"],
            timeout: 15,
            app: app
        )
        tapRequiredOnboardingStep(
            app.buttons["onboarding.baselineProfile.skip"],
            next: homeTab,
            timeout: 25,
            app: app
        )

        let greeting = app.staticTexts["dashboard.greeting"]
        let greetingAppeared = greeting.waitForExistence(timeout: 25)
        if !greetingAppeared { attachFailureDiagnostics(app: app, label: "dashboard-greeting-missing") }
        XCTAssertTrue(greetingAppeared, "Login did not reach the authenticated Dashboard shell")
    }

    /// **08-23.** The other half of the post-authentication route: an account
    /// the server already calls complete goes straight to the shell.
    ///
    /// This is not the tail walk with its assertions removed — it is the
    /// opposite claim, and it is the one 08-08 built. The two outcomes are
    /// raced rather than sampled in sequence, because "the optional tail did
    /// not appear" is only an observation while the route is still being
    /// decided; asked after the shell has settled it would be a glance at a
    /// screen the tail has already left. Whichever of the two mounts first is
    /// the answer, so the clause cannot pass by looking too late, and it cannot
    /// pass vacuously either: the shell landmark and the greeting still have to
    /// arrive.
    ///
    /// **Amended by 16-01 (K10), deliberately.** The clause it raced for was
    /// "the optional tail did not appear", and `onboarding.healthKit.skip` was
    /// its witness. That witness stopped being the right one: HealthKit
    /// authorization belongs to the handset, not to the account, and this run
    /// is a simulator that has never shown the system sheet — the fresh device
    /// the operator reported the "Apple Health nicht verbunden" dashboard on.
    /// So the device-local head is now expected here and is walked, and the
    /// claim the case was built for is asserted against the tail that is
    /// genuinely account-owned (`onboarding.aiSource.skip`). Same race, same
    /// reason for racing, a witness that still belongs to the account.
    @MainActor
    private func awaitShellWithoutOptionalSetup(_ app: XCUIApplication) {
        let homeTab = tabBarButton(app, symbol: "house.fill")
        // 16-01 — the device-local head this handset genuinely owes. Walking it
        // is not a weakening: skipping both steps asserts nothing about the
        // account-level tail, which is what the race below still measures.
        let healthKitStep = app.buttons["onboarding.healthKit.skip"]
        if healthKitStep.waitForExistence(timeout: 30) {
            // D-09-16-D — the same sheet-aware wait the tail walk uses. An
            // occluded button reports itself hittable, so this is not optional.
            _ = waitUntilOnboardingControlHittable(healthKitStep, app: app)
            healthKitStep.tap()
            let notifications = app.buttons["onboarding.notifications.skip"]
            if notifications.waitForExistence(timeout: 25) {
                _ = waitUntilOnboardingControlHittable(notifications, app: app)
                notifications.tap()
            }
        }

        let accountLevelTail = app.buttons["onboarding.aiSource.skip"]
        let deadline = Date().addingTimeInterval(30)
        var replayedSetup = false
        var reachedShell = false
        while Date() < deadline {
            replayedSetup = accountLevelTail.exists
            reachedShell = homeTab.exists
            if replayedSetup || reachedShell { break }
            usleep(200_000)
        }

        if replayedSetup { attachFailureDiagnostics(app: app, label: "completed-account-replayed-setup") }
        XCTAssertFalse(
            replayedSetup,
            "An account the server calls complete must not be replayed through the account-level setup tail"
        )
        if !reachedShell { attachFailureDiagnostics(app: app, label: "completed-account-shell-missing") }
        XCTAssertTrue(reachedShell, "Authentication succeeded but the authenticated shell never mounted")

        let greeting = app.staticTexts["dashboard.greeting"]
        let greetingAppeared = greeting.waitForExistence(timeout: 25)
        if !greetingAppeared { attachFailureDiagnostics(app: app, label: "dashboard-greeting-missing") }
        XCTAssertTrue(greetingAppeared, "Login did not reach the authenticated Dashboard shell")
    }

    @MainActor
    private func tapRequiredOnboardingStep(
        _ element: XCUIElement,
        next nextElement: XCUIElement,
        timeout: TimeInterval,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForExistence(timeout: timeout) else {
            attachFailureDiagnostics(app: app, label: "onboarding-tail-affordance-missing")
            XCTFail("Expected onboarding step affordance did not appear", file: file, line: line)
            return
        }

        guard waitUntilOnboardingControlHittable(element, app: app) else {
            attachFailureDiagnostics(app: app, label: "onboarding-tail-affordance-not-hittable")
            XCTFail("Onboarding step affordance exists but is not hittable", file: file, line: line)
            return
        }

        element.tap()

        let advanced = nextElement.waitForExistence(timeout: timeout)
        if !advanced { attachFailureDiagnostics(app: app, label: "onboarding-tail-did-not-advance") }
        XCTAssertTrue(advanced, "Onboarding step did not advance after tapping its skip affordance", file: file, line: line)
    }

    /// iOS Password AutoFill presents its post-login "Save Password?" prompt as
    /// a UIKit-owned `Sheet` inside `UITextEffectsWindow`, not as an XCUI alert
    /// or a SpringBoard interruption. Its delayed timing varies by runtime: it
    /// can cover HealthKit immediately or appear one step later on Notifications.
    ///
    /// **22-02 (D-09-16-D)** — the detection, the bounded dismissal and the
    /// refusals moved to `Support/SystemSheetDismissal.swift`, which also logs
    /// `ui-gate-dismissed-system-sheet label=…` so a release-gate log can tell
    /// "the sheet never appeared" from "the sheet appeared and was handled".
    /// They were private to this journey, so every other journey walking the
    /// same onboarding steps had no access to them — and this file sits at its
    /// 600-line ceiling, so sharing them meant moving them out.
    @MainActor
    private func dismissPasswordSaveSheetIfPresent(_ app: XCUIApplication) -> Bool {
        SystemSheetDismissal.dismissIfPresent(in: app)
    }

    @MainActor
    private func waitUntilOnboardingControlHittable(
        _ element: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var observedSheetFreeHittableSample = false
        while Date() < deadline {
            // Check the system-owned surface before trusting `isHittable`.
            // XCTest can report the underlying app button as hittable while
            // the delayed Password AutoFill sheet is already animating over it.
            if dismissPasswordSaveSheetIfPresent(app) {
                observedSheetFreeHittableSample = false
                continue
            }

            if element.isHittable {
                if observedSheetFreeHittableSample { return true }
                observedSheetFreeHittableSample = true
            } else {
                observedSheetFreeHittableSample = false
            }
            usleep(200_000)
        }

        return !app.sheets.firstMatch.exists && element.isHittable
    }

    /// **CU-06.** Resolve a tab-bar button by the SF Symbol it renders.
    ///
    /// This suite used to key the tab-bar landmarks off `shell.tab.<id>`
    /// accessibility identifiers set on the `Tab`s in `AuthenticatedShell`. Those
    /// identifiers never reached the accessibility tree — a `TabContent` forwards
    /// an accessibility *label* to its bar button but drops an *identifier*, so
    /// the buttons carry nothing but their localized label and every
    /// `tabBars.buttons["shell.tab.…"]` query missed. Both quarantines of these
    /// two tests were that miss, misread as simulator flakiness.
    ///
    /// The symbol name IS forwarded (`Image, …, identifier: 'ellipsis'`) and is
    /// exactly as locale-independent as the identifier was meant to be, so it is
    /// the landmark this suite can actually rely on. It is pinned to
    /// `AuthenticatedShell.tabDescriptors`, which is itself the declared
    /// "snapshot contract" for the bar.
    @MainActor
    private func tabBarButton(_ app: XCUIApplication, symbol: String) -> XCUIElement {
        app.tabBars.buttons.containing(.image, identifier: symbol).firstMatch
    }

    /// **CU-06.** Give an element that already *exists* a moment to become
    /// tappable before falling back to scrolling.
    ///
    /// Onboarding steps animate in, so `isHittable` is routinely still `false`
    /// in the instant `waitForExistence` returns. The previous
    /// `if !element.isHittable { app.swipeUp() }` fired on that first sample and
    /// scrolled a step that was merely still settling — and once it had swiped,
    /// the tap that followed logged `Computed hit point {-1, -1}`, i.e. never
    /// landed, and the step stayed un-skipped without anyone failing an
    /// assertion. Sampling until the deadline instead of once removes that
    /// class of miss; the swipe stays as the fallback for the case it was
    /// written for (a CTA genuinely below the fold).
    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(200_000)
        }
        return element.isHittable
    }

    // MARK: - Password login (non-MFA account)

    /// Task 03-02 reviewer smoke: ordinary password login, the HealthKit-denied
    /// (`Later`) branch, every remaining optional onboarding step, then shell.
    /// Each tap is required to be hittable and to reveal its declared successor;
    /// existence alone is not accepted as a transition.
    ///
    /// **08-23 — the scenario is a precondition, not a label.** Until Phase 8
    /// this case booted the default fixture and reached the tail regardless,
    /// because the post-authentication route consulted nothing. 08-08 made the
    /// server's `onboardingTourCompleted` load-bearing, and the default
    /// `/api/auth/me` row says `true` — so this walk stopped existing for that
    /// account and the case failed at the tail's first affordance while the
    /// Dashboard was already on screen behind it (element tree
    /// `onboarding-tail-affordance-missing-hierarchy` in
    /// `/tmp/xcresult-hl-08-16-authjourney-now.xcresult`: `dashboard.greeting`,
    /// the tab bar, `house.fill` Selected, and not one `onboarding.*` element).
    ///
    /// The optional tail is still a real obligation — for an account whose
    /// setup is genuinely outstanding. `returningLoginIncomplete` is that
    /// account, so the walk below is a flow the app ships rather than one it
    /// replaced, and every clause in ``skipOnboardingTailToDashboard(_:)`` is
    /// unchanged.
    @MainActor
    func testPasswordLoginWithHealthKitDeniedReachesShell() {
        let app = launchAuthJourney(extraArguments: ["-uitest-phase8", "returningLoginIncomplete"])
        submitPasswordLogin(app)
        skipOnboardingTailToDashboard(app)
    }

    // MARK: - MFA challenge sheet (v0158 flagship)

    @MainActor
    func testMfaChallengeSheetAppearsForMfaAccount() {
        let app = launchAuthJourney(extraArguments: ["-uitest-mfa-challenge"])
        submitPasswordLogin(app)

        let codeField = app.textFields["mfa.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 25), "MFA challenge sheet did not appear after login")
        // Still pre-auth — the shell must NOT be visible behind the sheet.
        XCTAssertFalse(app.staticTexts["dashboard.greeting"].exists, "Dashboard must not be reachable before the 2nd factor")
    }

    @MainActor
    func testMfaWrongCodeKeepsSheetWithError() {
        let app = launchAuthJourney(extraArguments: ["-uitest-mfa-challenge", "-uitest-mfa-verify-wrong"])
        submitPasswordLogin(app)

        let codeField = app.textFields["mfa.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 25), "MFA challenge sheet did not appear")
        codeField.tap()
        // A full 6-digit TOTP auto-submits (HIG one-time-code UX).
        codeField.typeText("000000")

        let error = app.staticTexts["mfa.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "A wrong code should surface an inline error")
        XCTAssertTrue(app.textFields["mfa.codeField"].exists, "The sheet must stay up for a retry after a wrong code")
    }

    @MainActor
    func testMfaDeadTicketEjectsToPasswordForm() {
        let app = launchAuthJourney(extraArguments: ["-uitest-mfa-challenge", "-uitest-mfa-verify-dead"])
        submitPasswordLogin(app)

        let codeField = app.textFields["mfa.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 25), "MFA challenge sheet did not appear")
        codeField.tap()
        codeField.typeText("654321")

        // A dead ticket clears the challenge and routes back to the password form.
        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "A dead ticket should route back to the password form")
        XCTAssertFalse(app.textFields["mfa.codeField"].exists, "The MFA sheet should be dismissed on a dead ticket")
    }

    /// **08-23 — this case keeps the default (complete) account deliberately.**
    ///
    /// It used to walk the same five-step tail as
    /// ``testPasswordLoginWithHealthKitDeniedReachesShell()`` and failed the
    /// same way, at the same line, with the Dashboard already on screen behind
    /// it. Both could have been repaired by booting `returningLoginIncomplete`
    /// — and then this release gate would carry two copies of one walk and no
    /// coverage at all of the completed-account route, which is the route an
    /// existing account takes and the one 08-08 shipped. So the two cases were
    /// split: that one proves the tail is still walkable for an account whose
    /// setup is outstanding, this one proves a completed account is not
    /// replayed through it. The claim about the second factor is unchanged —
    /// a correct code completes authentication and lands the user in the app.
    @MainActor
    func testMfaCorrectCodeReachesShell() {
        // No verify-override arg → the fixture serves a session for the code.
        let app = launchAuthJourney(extraArguments: ["-uitest-mfa-challenge"])
        submitPasswordLogin(app)

        let codeField = app.textFields["mfa.codeField"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 25), "MFA challenge sheet did not appear")
        codeField.tap()
        codeField.typeText("123456")

        awaitShellWithoutOptionalSetup(app)
    }

    // MARK: - Logout → onboarding

    /// Apple 5.1.1(v) release-path guard: the destructive flow must be reachable
    /// from the normal authenticated shell (not a DEBUG-only or deep-link-only
    /// surface) and must open the two-stage confirmation UI.
    @MainActor
    func testDeleteAccountIsReachableFromReleaseSettingsPath() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-hermetic",
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock"
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 30),
            "Hermetic boot did not reach the Dashboard"
        )

        let moreTab = tabBarButton(app, symbol: "ellipsis")
        XCTAssertTrue(moreTab.waitForExistence(timeout: 15), "More tab missing")
        moreTab.tap()

        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "Settings gear missing on More")
        gear.tap()

        let accountRow = anyElement(app, "settings.hub.account")
        XCTAssertTrue(accountRow.waitForExistence(timeout: 15), "Account row missing in Settings")
        accountRow.tap()

        let deleteRow = anyElement(app, "more.row.delete_account")
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 15), "Delete-account row missing on Account")
        deleteRow.tap()

        let consent = app.switches["deleteAccount.consentToggle"]
        XCTAssertTrue(consent.waitForExistence(timeout: 15), "Delete-account confirmation sheet did not open")
        XCTAssertTrue(app.buttons["deleteAccount.continueButton"].exists)
    }

    @MainActor
    func testLogoutReturnsToOnboarding() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-hermetic",
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock"
        ]
        app.launch()

        let dashboardAppeared = app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 30)
        if !dashboardAppeared { attachFailureDiagnostics(app: app, label: "logout-dashboard-missing") }
        XCTAssertTrue(dashboardAppeared, "Hermetic boot did not reach the Dashboard")

        // More tab → gear → Account → Sign out.
        let moreTab = tabBarButton(app, symbol: "ellipsis")
        let moreTabAppeared = moreTab.waitForExistence(timeout: 15)
        if !moreTabAppeared { attachFailureDiagnostics(app: app, label: "logout-more-tab-missing") }
        XCTAssertTrue(moreTabAppeared, "More tab missing")
        moreTab.tap()

        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "Settings gear missing on More")
        gear.tap()

        let accountRow = anyElement(app, "settings.hub.account")
        XCTAssertTrue(accountRow.waitForExistence(timeout: 15), "Account row missing in Settings")
        accountRow.tap()

        let signOut = anyElement(app, "more.row.sign_out")
        XCTAssertTrue(signOut.waitForExistence(timeout: 15), "Sign-out row missing on the Account screen")
        signOut.tap()

        answerLogoutConfirmation(app)

        // Logout drops the session → RootView swaps back to onboarding.
        let welcome = app.buttons["onboarding.welcome.cta"]
        let welcomeAppeared = welcome.waitForExistence(timeout: 25)
        if !welcomeAppeared { attachFailureDiagnostics(app: app, label: "logout-welcome-missing") }
        XCTAssertTrue(welcomeAppeared, "Logout should return to the onboarding welcome screen")
    }

    /// **08-23.** A sign-out is a two-step interaction now, and the first step
    /// is the product working rather than an obstacle.
    ///
    /// 08-09 put one native destructive confirmation in front of every
    /// sign-out. This case walked past it and waited 25 s for a welcome screen
    /// that was never coming: the element tree captured at that timeout
    /// (`/tmp/xcresult-hl-08-16-authjourney-now.xcresult`) shows an intact
    /// Account screen under an unanswered `Popover` holding
    /// `Sheet, label: 'Wirklich abmelden?'`, its consequence, and exactly one
    /// `Button, identifier: 'logout.confirm.signOut'`. The session refusing to
    /// end until the question is answered is precisely the guarantee 08-09
    /// exists to give, so the flow is walked instead of the assertion moved —
    /// and the two clauses that only became askable once something *is* raised
    /// are asserted here rather than assumed.
    ///
    /// The `.cancel`-role answer is deliberately not looked for: on iOS 26 the
    /// platform drops it and substitutes `PopoverDismissRegion`. That leg is
    /// 08-09's own `testLogoutConfirmationPreservesSessionOnCancel` and is not
    /// duplicated here.
    @MainActor
    private func answerLogoutConfirmation(_ app: XCUIApplication) {
        // D-17-09-A. 17-08 made the sheet substrate unreachable here, so this
        // waited the full 15 s before falling through. Order swapped, not
        // tolerance: both substrates stay answerable, the wait is spent on the
        // one that can appear (as Phase8AccessibilityUITests already does).
        let alert = app.alerts.firstMatch
        let dialog = alert.waitForExistence(timeout: 15) ? alert : app.sheets.firstMatch
        let dialogAppeared = dialog.exists
        if !dialogAppeared { attachFailureDiagnostics(app: app, label: "logout-confirmation-missing") }
        XCTAssertTrue(
            dialogAppeared,
            "Sign-out must raise a destructive confirmation before it ends the session"
        )
        guard dialogAppeared else { return }

        // The consequence has to be on screen before the destructive answer is
        // offered. The gate simulator renders German, so both catalogue values
        // of the one shared sentence are named — an English-keyed matcher here
        // would be a permanent false red about a product that speaks perfectly
        // (08-10).
        let spoken = ([dialog.label] + dialog.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " | ")
        XCTAssertTrue(
            ["sign in again", "erneut"].contains { spoken.localizedCaseInsensitiveContains($0) },
            "The sign-out confirmation never states what signing out costs: \(spoken)"
        )

        // Addressed by identifier and scoped to the dialog. `Abmelden` labels
        // both the row that opens the confirmation and the button that answers
        // it, so an app-wide label query would find the row and call it an
        // answer (08-09).
        //
        // `.firstMatch` is load-bearing and was measured: SwiftUI publishes the
        // dialog action as a `Button` nested inside a `Button` carrying the
        // *same* identifier, so the query resolves two elements and `tap()`
        // raises "Multiple matching elements found" before any assertion in
        // this file runs. Both are the same control at the same frame; taking
        // the first is disambiguation, not a relaxed match.
        let confirm = dialog.buttons[Self.logoutConfirmIdentifier].firstMatch
        let confirmExists = confirm.waitForExistence(timeout: 10)
        if !confirmExists { attachFailureDiagnostics(app: app, label: "logout-confirmation-has-no-answer") }
        XCTAssertTrue(confirmExists, "The sign-out confirmation offers no destructive answer")
        guard confirmExists else { return }
        confirm.tap()
    }

    /// Resolve an accessibility identifier across element types — `NavigationLink`
    /// rows and destructive `Button`s in a `List` don't always surface as
    /// `.buttons`, so match on `.any`.
    @MainActor
    private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
