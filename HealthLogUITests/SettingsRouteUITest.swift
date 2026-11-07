import XCTest

/// #153 (public #27) follow-up — leaving the app from a Settings page must
/// bring the user back to that same page.
///
/// The privacy shield replaces the whole window as soon as the scene stops
/// being active. ONBOARD kept what was typed (the container's in-memory
/// draft), but the pages themselves were pushed with view-based links that no
/// navigation path remembers, so the user came back to the Settings overview.
/// Both tests leave the app twice, once to the home screen and once only to
/// `.inactive` (Notification Center pulled over the app), and check the page
/// and the typed value each time.
final class SettingsRouteUITest: XCTestCase {
    private static let address = "route.example.com"
    private static let headerValue = "id-route-153"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings › Server, with the change-server sheet open and an address typed.
    @MainActor
    func testServerPageSurvivesLeavingTheApp() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 120)
        openServerPage(app)

        let change = app.descendants(matching: .any)["settings.server.changeServerButton"]
        XCTAssertTrue(change.waitForExistence(timeout: 10), "Change server row missing")
        change.tap()
        let field = app.textFields["settings.server.changeSheet.urlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Change server sheet did not open")
        replaceText(in: field, with: Self.address)

        leaveViaHome(app)
        assertServerSheetKept(app, after: "home")
        leaveViaNotificationCenter(app)
        assertServerSheetKept(app, after: "inactive")

        // Under the sheet is the Server page, not the Settings overview.
        app.buttons["settings.server.changeSheet.cancel"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.server.hostRow"].waitForExistence(timeout: 10),
            "Not back on the Server page under the sheet"
        )
    }

    /// Settings › Server › Access headers, with a header row and a value typed.
    @MainActor
    func testAccessHeadersPageSurvivesLeavingTheApp() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 120)
        openServerPage(app)

        let row = app.descendants(matching: .any)["settings.server.accessHeadersRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Access headers row missing")
        row.tap()
        let cloudflare = app.buttons["serverAccessHeaders.preset.cloudflare"]
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 10), "Access headers page did not open")
        cloudflare.tap()
        let values = app.secureTextFields.matching(identifier: "serverAccessHeaders.value")
        XCTAssertEqual(values.count, 2)
        values.element(boundBy: 0).tap()
        values.element(boundBy: 0).typeText(Self.headerValue)

        leaveViaHome(app)
        assertAccessHeadersKept(app, after: "home")
        leaveViaNotificationCenter(app)
        assertAccessHeadersKept(app, after: "inactive")

        // Back still discards: reopened, the page starts from the Keychain.
        // A filled secure field that left the window makes iOS offer to save
        // a password; that system prompt takes the first tap (probe G in the
        // SET-ROUTE report). The stack itself pops on the next one.
        dismissPasswordSavePrompt(app)
        app.navigationBars.buttons["BackButton"].tap()
        if !row.waitForExistence(timeout: 3) {
            app.navigationBars.buttons["BackButton"].tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Back did not return to the Server page")
        row.tap()
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 10), "Access headers page did not reopen")
        XCTAssertEqual(
            app.textFields.matching(identifier: "serverAccessHeaders.name").count, 0,
            "Back should have discarded the typed rows"
        )
    }

    /// POLISH-C (C2) — a page one level below the Settings overview:
    /// Account › Security comes back after the shield, not the Account page.
    @MainActor
    func testAccountSecurityPageSurvivesLeavingTheApp() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 120)
        openHubRow(app, "settings.hub.account")
        let security = app.descendants(matching: .any)["settings.account.securityRow"]
        XCTAssertTrue(security.waitForExistence(timeout: 10), "Security row missing on Account")
        security.tap()
        let passkeys = app.descendants(matching: .any)["settings.security.passkeysRow"]
        XCTAssertTrue(passkeys.waitForExistence(timeout: 10), "Security page did not open")

        leaveViaHome(app)
        XCTAssertTrue(passkeys.waitForExistence(timeout: 10), "After home: not on Account › Security any more")
        leaveViaNotificationCenter(app)
        XCTAssertTrue(passkeys.waitForExistence(timeout: 10), "After inactive: not on Account › Security any more")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(security.waitForExistence(timeout: 10), "Back did not return to Account")
    }

    /// POLISH-C (C2) — Integrations › Withings comes back after the shield.
    @MainActor
    func testWithingsPageSurvivesLeavingTheApp() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 120)
        openHubRow(app, "settings.hub.integrations")
        let row = app.descendants(matching: .any)["settings.integrations.withingsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Withings row missing on Integrations")
        row.tap()
        let bar = app.navigationBars["Withings"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Withings page did not open")

        leaveViaHome(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "After home: not on Integrations › Withings any more")
        leaveViaNotificationCenter(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "After inactive: not on Integrations › Withings any more")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Back did not return to Integrations")
    }

    /// POLISH-C (C3) — a filled access-header value is no password: after
    /// leaving the app, the first Back works, no "Save password?" prompt
    /// takes the tap.
    @MainActor
    func testFirstBackWorksAfterLeavingWithAFilledValue() {
        let app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(timeout: 120)
        openServerPage(app)
        let row = app.descendants(matching: .any)["settings.server.accessHeadersRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Access headers row missing")
        row.tap()
        let cloudflare = app.buttons["serverAccessHeaders.preset.cloudflare"]
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 10), "Access headers page did not open")
        cloudflare.tap()
        let values = app.secureTextFields.matching(identifier: "serverAccessHeaders.value")
        XCTAssertEqual(values.count, 2)
        values.element(boundBy: 0).tap()
        values.element(boundBy: 0).typeText(Self.headerValue)

        leaveViaHome(app)
        assertAccessHeadersKept(app, after: "home")
        assertNoPasswordPrompt(app, after: "home")
        leaveViaNotificationCenter(app)
        assertAccessHeadersKept(app, after: "inactive")
        assertNoPasswordPrompt(app, after: "inactive")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The first Back after leaving did nothing")
        assertNoPasswordPrompt(app, after: "back")
    }

    /// The system's "Save password?" offer, in the app or above it.
    @MainActor
    private func assertNoPasswordPrompt(_ app: XCUIApplication, after step: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let offered = [app, springboard].contains { host in
            ["Später", "Not Now", "Passwort sichern?", "Save Password?"].contains { host.buttons[$0].exists || host.staticTexts[$0].exists }
        }
        XCTAssertFalse(offered, "After \(step): iOS offered to save the access header value as a password")
    }

    /// Before/after evidence: what the user sees after coming back from the
    /// home screen, having typed on Settings › Server › Access headers. de/en,
    /// dark/light. Only runs when `TEST_RUNNER_HL_SWEEP_OUT` names a directory.
    @MainActor
    func testReturnShots() throws {
        let out = ProcessInfo.processInfo.environment["HL_SWEEP_OUT"] ?? ""
        try XCTSkipIf(out.isEmpty, "HL_SWEEP_OUT not set — shots only on request")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        continueAfterFailure = true
        for language in ["de", "en"] {
            for appearance in ["dark", "light"] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-AppleLanguages", "(\(language))",
                    "-AppleLocale", language == "de" ? "de_DE" : "en_US",
                    "-hl.settings.appearance", appearance,
                    "-hl.settings.darkDefault.reasserted.v1", "YES"
                ]
                app.launchHermeticAndWaitForDashboard(timeout: 120)
                openServerPage(app)
                let row = app.descendants(matching: .any)["settings.server.accessHeadersRow"]
                XCTAssertTrue(row.waitForExistence(timeout: 10))
                row.tap()
                let cloudflare = app.buttons["serverAccessHeaders.preset.cloudflare"]
                XCTAssertTrue(cloudflare.waitForExistence(timeout: 10))
                cloudflare.tap()
                leaveViaHome(app)
                Thread.sleep(forTimeInterval: 2)
                let shot = XCUIScreen.main.screenshot()
                try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/return-\(language)-\(appearance).png"))
                app.terminate()
            }
        }
    }

    // MARK: - Steps

    @MainActor
    private func openServerPage(_ app: XCUIApplication) {
        openHubRow(app, "settings.hub.serverSync")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.server.hostRow"].waitForExistence(timeout: 10),
            "Server page did not open"
        )
    }

    /// Mehr › gear › one row of the Settings overview.
    @MainActor
    private func openHubRow(_ app: XCUIApplication, _ identifier: String) {
        let more = app.phase8Tab("ellipsis")
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More tab missing")
        more.tap()
        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Settings gear missing")
        gear.tap()
        // The hub is a lazy `Form`: a lower row exists only once scrolled in.
        XCTAssertTrue(app.descendants(matching: .any)["settings.hub.account"].waitForExistence(timeout: 10), "Settings did not open")
        let target = app.descendants(matching: .any)[identifier]
        for _ in 0 ..< 8 where !(target.exists && target.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) missing")
        target.tap()
    }

    /// iOS offers to save the secure value as a password when the field goes
    /// away; the prompt belongs to the system and would swallow the next tap.
    @MainActor
    private func dismissPasswordSavePrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [app, springboard] {
            for label in ["Später", "Not Now"] where host.buttons[label].exists {
                host.buttons[label].tap()
                return
            }
        }
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        // Tap at the trailing edge so the cursor sits after the prefilled text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
        field.typeText(text)
    }

    /// The scene goes to the background and comes back.
    @MainActor
    private func leaveViaHome(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        let resigned = app.wait(for: .runningBackground, timeout: 10)
            || app.wait(for: .runningBackgroundSuspended, timeout: 10)
        XCTAssertTrue(resigned, "The app never left the foreground")
        app.activate()
    }

    /// Only `.inactive`: the shield shows, the scene never reaches the background.
    @MainActor
    private func leaveViaNotificationCenter(_ app: XCUIApplication) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        XCTAssertTrue(
            app.otherElements["privacyCover"].waitForExistence(timeout: 5),
            "Pulling Notification Center over the app should make the scene inactive"
        )
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        // Active again only once the shield is gone; a tap before that lands on
        // the closing Notification Center, not on the app.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["privacyCover"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "The shield stayed up")
    }

    @MainActor
    private func assertServerSheetKept(_ app: XCUIApplication, after leaving: String) {
        let field = app.textFields["settings.server.changeSheet.urlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "After \(leaving): not on the Server page with its sheet any more")
        XCTAssertEqual(field.value as? String, Self.address, "After \(leaving): the address was lost")
    }

    @MainActor
    private func assertAccessHeadersKept(_ app: XCUIApplication, after leaving: String) {
        let names = app.textFields.matching(identifier: "serverAccessHeaders.name")
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 10), "After \(leaving): not on the Access headers page any more")
        XCTAssertEqual(names.count, 2, "After \(leaving): the header rows were lost")
        XCTAssertEqual(names.element(boundBy: 0).value as? String, "CF-Access-Client-Id")
        // A secure field reports one bullet per character.
        let values = app.secureTextFields.matching(identifier: "serverAccessHeaders.value")
        XCTAssertEqual((values.element(boundBy: 0).value as? String)?.count, Self.headerValue.count, "After \(leaving): the value was lost")
    }
}
