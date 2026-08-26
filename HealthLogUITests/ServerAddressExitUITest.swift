import XCTest

/// **R1 — von der Anmeldefläche führt immer ein Weg zur Serveradresse.**
///
/// Der Betreiber saß auf `ServerAuthStep` fest: Passkey, E-Mail/Passwort und
/// SSO scheiterten alle an einer fehlenden bzw. nicht übernommenen
/// Serveradresse, und die Fläche bot keinen Knopf, der zu ihr zurückführte.
/// Der Zurück-Pfeil oben links existierte, hing aber am `previousStep`-Pfad
/// und war im Demo-/Einladungszweig kein Ausgang.
///
/// Dieser Test hält die Zusage fest, dass der Ausgang **immer** da ist — auch
/// wenn eine Adresse gesetzt ist (der Vertipper-Fall, der erst beim Anmelden
/// auffällt). Er läuft auf dem bestehenden `-uitest-auth-journey`-Boot, der
/// mit gesetzter Adresse auf dem Anmeldeschritt startet.
final class ServerAddressExitUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAuthStepAlwaysOffersAWayBackToTheServerAddress() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-auth-journey",
            "-uitest-disable-biometric-lock"
        ]
        app.launch()

        let signIn = app.buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "Auth step never appeared")

        let changeServer = app.buttons["onboarding.changeServerCTA"]
        XCTAssertTrue(
            changeServer.waitForExistence(timeout: 10),
            "The sign-in surface must always offer a way to the server address"
        )
        if !changeServer.isHittable { app.swipeUp() }
        changeServer.tap()

        let urlField = app.textFields["onboarding.serverCustom"]
        XCTAssertTrue(
            urlField.waitForExistence(timeout: 10),
            "Tapping the exit must reach the server-address step"
        )
        // Der Vertipper-Fall: das Feld trägt die bisherige Adresse, damit sie
        // korrigiert und nicht blind neu getippt werden muss.
        XCTAssertEqual(
            urlField.value as? String,
            "https://uitest.hermetic.local",
            "The address step must show the address that is currently configured"
        )
    }
}
