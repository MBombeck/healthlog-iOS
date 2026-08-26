import XCTest

/// **Phase 16 Plan 01 — K10, walked end to end on a fresh device.**
///
/// The walkthrough's complaint was not "a step is broken". It was that a step
/// the app has was never offered: the operator's new install signed into an
/// account the server already calls complete, went straight to the shell, and
/// the dashboard then told him Apple Health was not connected. 08-08's skip is
/// account-wide by design — the web onboarding sets the same flag — while
/// HealthKit authorization belongs to the handset and travels nowhere.
///
/// This class walks the repaired route and is deliberately not the amended
/// 08-08 pin with its assertions moved around. That pin *skips* the two
/// device-local steps and measures that the account-level tail stays skipped;
/// this one *completes* the HealthKit request — through the DEBUG
/// `-uitest-permission-outcome` seam, because the system sheet is presented out
/// of process and cannot be driven — and measures that a granted device-local
/// head hands over to the shell just as a skipped one does. A route that only
/// works when the user declines is not the route this plan shipped.
///
/// Hermetic: `-uitest-auth-journey` + the Phase-8 `returningLoginCompleted`
/// fixture. No network, no credential, no real permission.
final class OnboardingRoutingUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let email = "hermetic@uitest.local"
    private static let password = "hunter2hunter2"

    @MainActor
    func testCompletedAccountOnAFreshDeviceIsAskedForHealthKitThenReachesShell() {
        let app = XCUIApplication()
        app.launchPhase8Onboarding(
            .returningLoginCompleted,
            extraArguments: ["-uitest-permission-outcome", "granted"]
        )
        submitLogin(app)

        // K10 — the ask that never happened. A device that has never shown the
        // system sheet is asked for it, whatever the account flag says.
        let connect = app.buttons["onboarding.healthKit.connect"]
        let asked = connect.waitForExistence(timeout: 30)
        if !asked { attachFailureDiagnostics(app: app, label: "k10-healthkit-step-missing") }
        XCTAssertTrue(
            asked,
            "A device that never granted HealthKit must be asked during onboarding, not told afterwards"
        )
        guard asked else { return }
        tapWhenHittable(connect, in: app)

        // Granting advances to the second device-local step under its own steam.
        let notifications = app.buttons["onboarding.notifications.skip"]
        let advanced = notifications.waitForExistence(timeout: 25)
        if !advanced { attachFailureDiagnostics(app: app, label: "k10-notifications-step-missing") }
        XCTAssertTrue(advanced, "A completed HealthKit request must advance to the notifications step")
        guard advanced else { return }
        tapWhenHittable(notifications, in: app)

        // And the device-local head ends at the shell — the account-level tail
        // this account answered elsewhere is not replayed behind it.
        let replayed = app.buttons["onboarding.aiSource.skip"].waitForExistence(timeout: 10)
        if replayed { attachFailureDiagnostics(app: app, label: "k10-account-tail-replayed") }
        XCTAssertFalse(
            replayed,
            "Completing the device-local half must not reopen the account-level tail"
        )

        let greeting = app.staticTexts["dashboard.greeting"]
        let reached = greeting.waitForExistence(timeout: 30)
        if !reached { attachFailureDiagnostics(app: app, label: "k10-shell-missing") }
        XCTAssertTrue(reached, "The device-local setup did not hand over to the authenticated shell")
    }

    // MARK: - Journey helpers

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

    /// Sample until the control is genuinely tappable, checking the
    /// system-owned surface first.
    ///
    /// **D-09-16-D, met on this class's first run.** After a fixture password
    /// login iOS raises its Password AutoFill prompt as a UIKit-owned `Sheet`
    /// (`{{41.0, 315.0}, {320.0, 272.0}}`, label `'Passwort sichern?'`) over the
    /// HealthKit step, and the tap underneath it logs `Computed hit point
    /// {-1, -1}` — it never lands, and nothing fails to say so. Swiping instead
    /// of dismissing scrolls a step that was merely covered. The shape and the
    /// handling are `AuthJourneyUITest`'s and `Phase8OnboardingUITests`', copied
    /// deliberately rather than re-derived, including the refusal to touch an
    /// alert or an input-bearing sheet so an app-owned error surface can never
    /// be tapped away here.
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
    /// carrying no input.
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
}
