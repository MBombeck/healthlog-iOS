import XCTest

/// **Phase 08 Wave 0 — the returning login and the optional setup tail.**
///
/// Boots unauthenticated through `-uitest-auth-journey` + `-uitest-phase8` and
/// drives the real login form against the fixture backend, whose `/api/auth/me`
/// already answers `onboardingTourCompleted: true`. No network, no credential,
/// no real permission is involved: the HealthKit and notification steps are only
/// ever *skipped*, never authorised, so no out-of-process system sheet can enter
/// the run.
final class Phase8OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let email = "hermetic@uitest.local"
    private static let password = "hunter2hunter2"

    // MARK: RED — a completed returning user is not re-asked

    /// The server says this account finished setup, `OnboardingTourStore` reads
    /// it on every authentication tick, and nothing consumes the answer: all
    /// four sign-in legs land on `.authenticating` and `handlePhase` moves
    /// to `.healthKit` regardless. So the returning user meets the optional
    /// permission tail again, every time.
    ///
    /// **Closed by 08-08.** The transition now awaits the completion lookup and
    /// resolves it. Not one assertion below changed: the case reads the screen,
    /// and the screen is now the shell.
    ///
    /// **Amended by 16-01, deliberately, and renamed to say what it now pins.**
    /// 08-08's skip was right for the steps it was built for and wrong for the
    /// two it also swallowed. `onboardingTourCompleted` is an ACCOUNT fact —
    /// the web onboarding sets it — while HealthKit authorization belongs to
    /// the handset, so this run (a simulator that has never shown the system
    /// sheet) is exactly the fresh device K10 was reported on: the operator's
    /// new install went straight to a dashboard that then told him Apple Health
    /// was not connected. The device-local head is therefore now REQUIRED here,
    /// and what must stay skipped is the account-level tail — the AI-source,
    /// anamnesis and baseline-profile steps this account answered elsewhere.
    /// The pin has moved; it has not been weakened, and both directions are
    /// still asserted.
    @MainActor
    func testCompletedReturningLoginSkipsTheAccountLevelTail() {
        let app = XCUIApplication()
        app.launchPhase8Onboarding(.returningLoginCompleted)
        submitLogin(app)

        var violations: [String] = []
        let deviceLocalStep = app.buttons["onboarding.healthKit.skip"]
        if !deviceLocalStep.waitForExistence(timeout: 25) {
            violations.append("a device that never granted HealthKit was not asked for it (K10)")
        } else {
            // D-09-16-D — through the class's own helper, which declines the
            // Password AutoFill sheet before trusting `isHittable`. A raw
            // `.tap()` here logs `Computed hit point {-1, -1}` and lands nowhere.
            tapWhenHittable(deviceLocalStep, in: app)
            let notifications = app.buttons["onboarding.notifications.skip"]
            if !notifications.waitForExistence(timeout: 25) {
                violations.append("the device-local head stopped after HealthKit instead of reaching notifications")
            } else {
                tapWhenHittable(notifications, in: app)
                // The tail 08-08 skipped must still be skipped: the next thing
                // on screen is the shell, not the AI-source step.
                if app.buttons["onboarding.aiSource.skip"].waitForExistence(timeout: 10) {
                    violations.append("the account-level tail was replayed for an account the server calls complete")
                } else if !app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 25) {
                    violations.append("the device-local head did not hand over to the shell")
                }
            }
        }
        record(violations, for: "returning-login")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI completed returning login replayed optional setup"
        )
    }

    // MARK: RED — a refused permission is stated, not swallowed

    /// Neither permission step carries an identified surface for a denial or an
    /// authorisation error — `HealthKitPermissionStep` exposes only its skip
    /// affordance and a backfill picker, `NotificationsPermissionStep` only its
    /// skip. A refusal is therefore not merely unhandled, it is unfalsifiable:
    /// no automated check can establish that anything was ever said about it.
    ///
    /// **Closed by 08-10, and the case now drives the refusal it is named
    /// after.** The two original clauses are intact, but they no longer ask
    /// whether a denial surface exists *in the abstract* — a step could satisfy
    /// that by showing a denial message at a user who denied nothing. The run
    /// now taps the request affordance with `-uitest-permission-outcome
    /// declined`, which replaces the *answer* the service would have given and
    /// nothing else (the system sheet is presented out of process and iOS
    /// raises it once per install, so no hermetic run can produce a real
    /// refusal), and then requires the surface, the affordances a refusal
    /// earns, and — the actual defect — that the flow did **not** advance.
    @MainActor
    func testPermissionFailuresAreActionable() {
        // 08-08 — this case is about what the permission steps say, and it needs
        // to *be* on them. Since the route now reads the server's completion
        // flag, reaching the tail is something a scenario has to ask for.
        let app = XCUIApplication()
        app.launchPhase8Onboarding(
            .returningLoginIncomplete,
            extraArguments: ["-uitest-permission-outcome", "declined"]
        )
        submitLogin(app)

        var violations: [String] = []
        let healthKitSkip = app.buttons["onboarding.healthKit.skip"]
        guard app.awaitPhase8(healthKitSkip, "the HealthKit permission step", timeout: 25) else { return }
        let connect = app.buttons["onboarding.healthKit.connect"]
        guard app.awaitPhase8(connect, "the HealthKit connect affordance") else { return }
        tapWhenHittable(connect, in: app)

        if !app.descendants(matching: .any)["onboarding.healthKit.denied"].waitForExistence(timeout: 10) {
            violations.append("the HealthKit step exposes no identified surface for a denied authorization")
        }
        if !app.buttons["onboarding.healthKit.retry"].exists {
            violations.append("an unsuccessful HealthKit authorization offers no way to ask again")
        }
        if !healthKitSkip.exists {
            violations.append("an unsuccessful HealthKit authorization advanced the flow as if it had been granted")
        }
        tapWhenHittable(healthKitSkip, in: app)

        let notificationsSkip = app.buttons["onboarding.notifications.skip"]
        guard app.awaitPhase8(notificationsSkip, "the notifications permission step") else { return }
        let allow = app.buttons["onboarding.notifications.allow"]
        guard app.awaitPhase8(allow, "the notifications allow affordance") else { return }
        tapWhenHittable(allow, in: app)

        if !app.descendants(matching: .any)["onboarding.notifications.denied"].waitForExistence(timeout: 10) {
            violations.append("the notifications step exposes no identified surface for a denied authorization")
        }
        if !app.buttons["onboarding.notifications.openSettings"].exists {
            violations.append("a declined notification permission offers no route into Settings")
        }
        if !app.buttons["onboarding.notifications.continue"].exists {
            violations.append("a declined notification permission offers no deliberate way past it")
        }
        if !notificationsSkip.exists {
            violations.append("a declined notification permission advanced the flow as if it had been granted")
        }
        record(violations, for: "permission-failure")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI permission failure advanced without actionable feedback"
        )
    }

    // MARK: RED — profile input is validated where it is typed

    /// `saveThenContinue()` collects a height only when it parses into
    /// `50...300`. An out-of-range entry is therefore dropped without a word,
    /// and — when it was the only thing typed — `guard dirty else { onNext() }`
    /// advances the flow as if the value had been saved. The user's input is
    /// gone and the step says nothing.
    ///
    /// The preservation half is next to it: a *refused* write does surface
    /// `onboarding.baselineProfile.saveFailed` and does not advance (audit 02
    /// M-5). Validation is the half that is missing, not error handling.
    @MainActor
    func testProfileValidationAndPartialFailureRemainActionable() {
        let app = XCUIApplication()
        app.launchPhase8Onboarding(.onboardingProfileFailure)
        submitLogin(app)
        guard skipToBaselineProfile(app) else { return }

        let height = app.textFields["onboarding.baselineProfile.height"]
        guard app.awaitPhase8(height, "the profile height field") else { return }
        let proceed = app.buttons["onboarding.baselineProfile.continue"]
        guard app.awaitPhase8(proceed, "the profile Continue button") else { return }

        var violations: [String] = []

        // 08-10 — the preservation half first, walked rather than asserted from
        // the source: a plausible height makes the patch dirty, this scenario
        // refuses the write, and the step has to say so and stay.
        height.tap()
        height.typeText("170")
        tapWhenHittable(proceed, in: app)
        if !proceed.waitForExistence(timeout: 5) {
            violations.append("a refused profile write advanced the flow as if it had been saved")
        } else if !app.descendants(matching: .any)["onboarding.baselineProfile.saveFailed"]
            .waitForExistence(timeout: 10)
        {
            violations.append("a refused profile write surfaced no failure")
        }

        // Then the half that was missing. Two zeros are *appended* rather than
        // the field being cleared: a `numberPad` has no reliable programmatic
        // clear (the first attempt typed four `XCUIKeyboardKey.delete`s and the
        // field kept its digits), while any insertion of "00" into "170" is a
        // five-digit number and therefore out of range wherever the caret sat.
        height.tap()
        height.typeText("00")
        tapWhenHittable(proceed, in: app)

        let stillOnStep = proceed.waitForExistence(timeout: 5)
        // 08-10 — the clause is unchanged; how it looks is not. It used to read
        // both identifiers with a bare `.exists` on the very next line after the
        // tap, which samples the accessibility tree before SwiftUI has rendered
        // the verdict, and it read the failure surface as a `StaticText` when
        // the element it resolves to is not necessarily one. Waiting for either
        // surface can only ever *remove* a false violation: an absent message
        // after ten seconds is still an absent message.
        let stated = app.descendants(matching: .any)["onboarding.baselineProfile.invalidHeight"]
            .waitForExistence(timeout: 10)
            || app.descendants(matching: .any)["onboarding.baselineProfile.saveFailed"].exists
        if !stillOnStep {
            violations.append("an out-of-range height advanced the flow as if it had been saved")
        } else if !stated {
            attachFailureDiagnostics(app: app, label: "profile-validation")
            violations.append("an out-of-range height was discarded with no validation message")
        }
        record(violations, for: "profile-validation")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI profile failure was hidden or advanced"
        )
    }

    // MARK: RED — the indicator speaks the route it shows

    /// `ProgressIndicator` speaks `"\(Int(progress * 100)) percent"` — an
    /// untranslated English literal built from a ten-case table of hand-tuned
    /// fractions. A user who cannot see the bar is told a number that names no
    /// step, in a language that may not be theirs, while the visible route is
    /// the thing they actually need.
    @MainActor
    func testResolvedRouteDrivesProgressAndBackNavigation() {
        // 08-08 — same reason as above: the second half of this case reads the
        // spoken progress *on the setup tail*, so the tail has to be reached.
        let app = XCUIApplication()
        app.launchPhase8Onboarding(.returningLoginIncomplete)

        var violations: [String] = []
        let atAuth = spokenProgress(app)
        if let atAuth {
            if atAuth.value.range(of: "^[0-9]+ percent$", options: .regularExpression) != nil {
                violations.append("the resolved route is spoken as the raw percentage \"\(atAuth.value)\"")
            }
            if atAuth.label.isEmpty || atAuth.value.range(of: Self.positionPattern, options: .regularExpression) == nil {
                violations.append("the spoken value names no position in the route the label describes")
            }
        } else {
            violations.append("no element exposes the onboarding progress to assistive technology")
        }

        let healthKitSkip = app.buttons["onboarding.healthKit.skip"]
        submitLogin(app)
        guard app.awaitPhase8(healthKitSkip, "the setup tail", timeout: 25) else { return }
        if let atHealthKit = spokenProgress(app), atHealthKit.value == atAuth?.value {
            violations.append("the spoken progress did not change when the resolved route did")
        }

        // 08-10 — the half this case is named after and never measured. The
        // prior *active* route step of the notifications step is HealthKit, and
        // the control that goes there has to be worth aiming at.
        tapWhenHittable(healthKitSkip, in: app)
        guard app.awaitPhase8(app.buttons["onboarding.notifications.skip"], "the notifications step") else { return }
        let back = app.buttons["onboarding.backButton"]
        if !back.waitForExistence(timeout: 10) {
            violations.append("the setup tail offers no back affordance to the prior active route")
        } else {
            let region = back.frame
            if region.width < 43.5 || region.height < 43.5 {
                violations.append(
                    "the back control resolves to \(Int(region.width))x\(Int(region.height)), under the 44pt minimum"
                )
            }
            tapWhenHittable(back, in: app)
            if !healthKitSkip.waitForExistence(timeout: 10) {
                violations.append("back from the notifications step did not return to the prior active route")
            }
        }
        record(violations, for: "progress-semantics")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI progress did not match the resolved route"
        )
    }

    // MARK: - Journey

    /// The seeded credentials, entered into the real login form. Mirrors the
    /// sequence `AuthJourneyUITest` proved: dismiss the keyboard with a return
    /// before submitting, and wait for the CTA to become hittable.
    @MainActor
    private func submitLogin(_ app: XCUIApplication) {
        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        guard app.awaitPhase8(signIn, "the sign-in CTA", timeout: 25) else { return }

        let emailField = app.textFields.firstMatch
        guard app.awaitPhase8(emailField, "the email field") else { return }
        emailField.tap()
        emailField.typeText(Self.email)

        let passwordField = app.secureTextFields.firstMatch
        guard app.awaitPhase8(passwordField, "the password field") else { return }
        passwordField.tap()
        passwordField.typeText(Self.password)
        passwordField.typeText("\n")

        tapWhenHittable(signIn, in: app)
    }

    /// Walks the four skippable optional steps to the baseline-profile step.
    @MainActor
    private func skipToBaselineProfile(_ app: XCUIApplication) -> Bool {
        for identifier in [
            "onboarding.healthKit.skip",
            "onboarding.notifications.skip",
            "onboarding.aiSource.skip",
            "onboarding.anamnesis.skip"
        ] {
            let step = app.buttons[identifier]
            guard app.awaitPhase8(step, "the \(identifier) affordance", timeout: 25) else { return false }
            tapWhenHittable(step, in: app)
        }
        return true
    }

    /// Waits for an onboarding control to be genuinely tappable.
    ///
    /// The first gate run lost two cases here. After a fixture login iOS raises
    /// its Password AutoFill "Save Password?" prompt as a UIKit-owned *sheet*
    /// over the step — not an alert, not a SpringBoard interruption — and
    /// XCTest happily reports the occluded button as hittable. Swiping instead
    /// of dismissing scrolled a step that was merely covered, and the tap never
    /// landed. This is the shape `AuthJourneyUITest` measured and proved.
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 12) {
        let deadline = Date().addingTimeInterval(timeout)
        var sawSheetFreeSample = false
        while Date() < deadline {
            if dismissPasswordSaveSheetIfPresent(app) {
                sawSheetFreeSample = false
                continue
            }
            if element.isHittable {
                if sawSheetFreeSample { break }
                sawSheetFreeSample = true
            } else {
                sawSheetFreeSample = false
            }
            usleep(200_000)
        }
        if !element.isHittable { app.swipeUp() }
        element.tap()
    }

    /// Dismisses the Password AutoFill prompt, and only that: a two-button sheet
    /// carrying no input. Anything else — an alert, a sheet with fields, a sheet
    /// of another shape — is left alone and fails the test, so an app-owned
    /// error surface can never be tapped away by this helper.
    @MainActor
    @discardableResult
    private func dismissPasswordSaveSheetIfPresent(_ app: XCUIApplication) -> Bool {
        let sheet = app.sheets.firstMatch
        guard sheet.exists else { return false }
        guard !app.alerts.firstMatch.exists else { return false }
        guard sheet.buttons.count == 2,
              !sheet.textFields.firstMatch.exists,
              !sheet.secureTextFields.firstMatch.exists else { return false }
        let decline = sheet.buttons.element(boundBy: 0)
        guard decline.isHittable else { return false }
        decline.tap()
        return sheet.waitForNonExistence(timeout: 2)
    }

    /// Records what a RED actually found, so the gate log carries the evidence
    /// the single fixed marker cannot.
    private func record(_ violations: [String], for test: String) {
        print("PHASE8-VIOLATIONS \(test): \(violations)")
    }

    /// "Somewhere in the route, out of how many" — two numbers with anything
    /// between them, in any language.
    ///
    /// **08-10 finding.** The pattern this replaced was `.*[Ss]tep.*`, and the
    /// clause beside it read `value.localizedCaseInsensitiveContains("step")`.
    /// Both are English, and **the gate simulator runs in German**: the moment
    /// the spoken value became a localized position — "Schritt 4 von 8" — no
    /// English-keyed matcher could ever find it again, so a correctly localized
    /// product would have reported "no element exposes the onboarding progress
    /// to assistive technology" forever. Nothing was weakened: the case still
    /// requires a progress element, still refuses a raw percentage, and still
    /// requires the value to name a position. Only the way a position is
    /// recognised stopped assuming a locale.
    private static let positionPattern = "[0-9]+[^0-9]+[0-9]+"

    /// The onboarding indicator as assistive technology reads it: an element
    /// that ignores its children and carries a label and a value.
    ///
    /// Looked up by identifier first (08-10 gave the indicator a stable one) and
    /// only then by shape, so the fallback stays available to *fail* — an app
    /// that stops speaking its progress must still be observable as such.
    ///
    /// Matched with a predicate rather than by walking every element: the first
    /// gate run walked `allElementsBoundByIndex` and the tree moved underneath
    /// it ("No matches found for Element at index 36"), so the case failed on a
    /// stale snapshot instead of on its own claim.
    @MainActor
    private func spokenProgress(_ app: XCUIApplication) -> (label: String, value: String)? {
        let identified = app.descendants(matching: .any)["onboarding.progress"]
        if identified.exists, let value = identified.value as? String, !value.isEmpty {
            return (identified.label, value)
        }
        for pattern in ["^[0-9]+ percent$", "^[^0-9]*\(Self.positionPattern)[^0-9]*$"] {
            let match = app.descendants(matching: .any)
                .matching(NSPredicate(format: "value MATCHES %@", pattern))
                .firstMatch
            guard match.exists, let value = match.value as? String else { continue }
            return (match.label, value)
        }
        return nil
    }
}
