import XCTest

/// 1.5 KONTO — the account and connection copy against both server
/// generations: the delete and reset screens against a 1.46 server with a
/// 14-day grace window (`-uitest-konto`) and against the default fixture server
/// (1.37, erases at once), the retired Fitbit row and screen, and the sign-in
/// refusal of an account locked for deletion. Runs with the sweep's language,
/// appearance and text size. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_18k_kontoSurfaces() {
        boot(extra: ["-uitest-konto"])
        openAccountSettings()
        kontoSheet("more.row.delete_account", "18k-delete-146")
        kontoSheet("settings.account.resetDataRow", "18k-reset-146")
        goBackToHub()
        if tap(element("settings.hub.integrations"), "integrations") {
            settle(3)
            if let fitbit = probe("settings.integrations.fitbitRow") {
                shot("18k-integrations-fitbit-row")
                fitbit.tap()
                settle(4)
                shotToEnd("18k-fitbit-retired")
            } else {
                note("Fitbit row not present")
            }
        }

        app.terminate()
        boot()
        openAccountSettings()
        kontoSheet("more.row.delete_account", "18k-delete-older")

        app.terminate()
        signInRefusal()
    }

    private func openAccountSettings() {
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        if let account = probe("settings.hub.account") {
            account.tap()
            settle(3)
        }
    }

    private func goBackToHub() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        settle(2)
    }

    /// Opens the sheet behind `row`, photographs it to its end, closes it.
    private func kontoSheet(_ row: String, _ name: String) {
        scrollUpToTop()
        guard let target = probe(row) else {
            note("row not present: \(row)")
            return
        }
        target.tap()
        settle(3)
        shotToEnd(name)
        // Swipe the sheet away by its grabber: the close button's label is
        // language-dependent and the bar below the sheet has buttons too.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        settle(2)
    }

    /// The password sign-in of an account pending deletion (403 with a date).
    private func signInRefusal() {
        app = XCUIApplication()
        app.launchArguments += language.launchArguments + [
            "-uitest-auth-journey",
            "-uitest-disable-biometric-lock",
            "-uitest-konto-deletion-pending"
        ]
        if env["HL_SWEEP_APPEARANCE"] == "light" {
            app.launchArguments += HermeticAppearance.lightArguments
        }
        app.launch()
        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        guard signIn.waitForExistence(timeout: 30) else {
            note("sign-in CTA never appeared")
            return
        }
        let email = app.textFields.firstMatch
        if email.waitForExistence(timeout: 5) {
            email.tap()
            email.typeText("tester@example.com")
        }
        let password = app.secureTextFields.firstMatch
        if password.waitForExistence(timeout: 5) {
            password.tap()
            password.typeText("fixture-pass\n")
        }
        if signIn.isHittable { signIn.tap() }
        settle(4)
        shot("18k-signin-deletion-pending")
    }
}
