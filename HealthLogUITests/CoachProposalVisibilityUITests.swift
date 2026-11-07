import XCTest

/// **1.5 COACH-R** — after sending, the keyboard stays open (as everywhere in
/// the Coach chat). A plan proposal and the trail link arrive after the answer;
/// the transcript must bring them up above the keyboard, so both buttons and
/// the link can be tapped without closing the keyboard first.
///
/// World: the hermetic shell with `-uitest-coach-r` (a v1.41 Coach whose answer
/// arrives about 12 s after the question, then a plan proposal and a trail),
/// `-uitest-citations` (a configured provider, so the AI consent can be
/// accepted and the Coach runs on the server arm).
@MainActor
final class CoachProposalVisibilityUITests: XCTestCase {
    func test_proposalAndTrailLinkReachableAboveKeyboard() throws {
        try runProposalCheck(extra: [], expectTrailLink: true)
    }

    /// The same at the largest accessibility text size: the proposal card is
    /// then taller than half the free space, and the scroll must still end on
    /// its buttons.
    func test_proposalReachableAboveKeyboardAtLargestText() throws {
        try runProposalCheck(
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"],
            expectTrailLink: false
        )
    }

    /// Settings, Assistant: „Erweitert" opens the thinking-depth card, and its
    /// last option can be brought above the tab bar.
    func test_reasoningCardReachableAboveTabBar() {
        let app = launch(extra: [])
        app.tabBars.buttons.containing(.image, identifier: "ellipsis").firstMatch.tap()
        XCTAssertTrue(app.buttons["more.toolbar.gear"].waitForExistence(timeout: 10))
        app.buttons["more.toolbar.gear"].tap()
        let aiRow = app.descendants(matching: .any).matching(identifier: "settings.hub.ai").firstMatch
        XCTAssertTrue(scrollUntilAboveTabBar(aiRow, in: app), "Settings, Assistant row missing")
        aiRow.tap()
        let advanced = app.buttons["settings.ai.advanced"]
        XCTAssertTrue(scrollUntilAboveTabBar(advanced, in: app), "Advanced link not reachable above the tab bar")
        advanced.tap()
        let high = app.buttons["settings.ai.reasoning.option.high"]
        XCTAssertTrue(scrollUntilAboveTabBar(high, in: app), "Last thinking-depth option not reachable above the tab bar")
    }

    // MARK: - Helpers

    private func runProposalCheck(extra: [String], expectTrailLink: Bool) throws {
        let app = launch(extra: extra)
        try XCUIDevice.shared.system.open(XCTUnwrap(URL(string: "healthlog://coach")))
        for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
            let coin = app.buttons[id]
            if coin.waitForExistence(timeout: 8), coin.isHittable {
                coin.tap()
                break
            }
        }
        acceptConsent(app)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Coach input missing")
        field.tap()
        field.typeText("Wie habe ich diese Woche geschlafen?")
        // POLISH-B B1 — the composer sits above the open keyboard before the
        // first question. On iOS 26.5 at AX-XXL the welcome and the chips, a
        // fixed block above the transcript, pushed it under the keyboard; the
        // tap on "send" then hit a key and no question was ever sent.
        let send = app.buttons["Frage senden"]
        let keyboardUp = app.keyboards.firstMatch
        XCTAssertTrue(keyboardUp.waitForExistence(timeout: 5), "The keyboard should be open while typing")
        XCTAssertLessThanOrEqual(
            send.frame.maxY, keyboardUp.frame.minY,
            "The send button must sit above the keyboard"
        )
        send.tap()

        let accept = app.buttons["coach.proposal.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 40), "No plan proposal arrived")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists, "The keyboard should stay open after sending")
        var targets = [accept, app.buttons["coach.proposal.dismiss"]]
        if expectTrailLink { targets.append(app.buttons["coach.trail.link"]) }
        for target in targets {
            // Above the keyboard, without anybody scrolling.
            let visible = NSPredicate { _, _ in
                target.exists && target.isHittable && target.frame.maxY <= keyboard.frame.minY
            }
            expectation(for: visible, evaluatedWith: target)
        }
        waitForExpectations(timeout: 10)
    }

    private func launch(extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"] + extra
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-uitest-marketing", "-uitest-sweep", "-uitest-coach-r", "-uitest-citations",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        acceptConsent(app)
        return app
    }

    private func scrollUntilAboveTabBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0 ..< 8 {
            if element.waitForExistence(timeout: 2), element.isHittable,
               element.frame.maxY < app.tabBars.firstMatch.frame.minY
            {
                return true
            }
            app.swipeUp()
        }
        return false
    }

    private func acceptConsent(_ app: XCUIApplication) {
        for label in ["Akzeptieren", "Accept"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                return
            }
        }
    }
}
