import XCTest

/// 1.5 COACH-R — the Coach against a v1.41 server (`-uitest-coach-r`,
/// `CoachRFixtures`): the thinking depth under „Erweitert" in Settings,
/// Assistant, the running answer with its status line, the plan proposal and
/// the opened trail. The AI consent is accepted (`-uitest-citations` configures
/// a provider), so the Coach runs on the server arm. Runs with the sweep's
/// language, appearance and text size. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19c_coachReasoning() {
        bootAcceptingAI(extra: ["-uitest-coach-r", "-uitest-citations"])
        let tag = isXXL ? "19c-xxl" : "19c"

        tab("ellipsis")
        if tap(app.buttons["more.toolbar.gear"], "settings gear") {
            settle(2)
            if let row = probe("settings.hub.ai") {
                row.tap()
                settle(3)
                if let advanced = advancedLink() {
                    shot("\(tag)-settings-closed")
                    advanced.tap()
                    settle(2)
                    app.swipeUp()
                    settle(1.5)
                    shot("\(tag)-settings-reasoning")
                    if probe("settings.ai.reasoning.option.high") != nil { shot("\(tag)-settings-reasoning-end") }
                } else {
                    note("coach-r: no Advanced link on Settings, Assistant")
                    shot("\(tag)-settings-missing")
                }
            }
        }
        app.terminate()
        bootAcceptingAI(extra: ["-uitest-coach-r", "-uitest-citations"])

        openDeepLink("healthlog://coach")
        settle(5)
        for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
            let coin = app.buttons[id]
            if coin.waitForExistence(timeout: 3), coin.isHittable {
                coin.tap()
                settle(3)
                break
            }
        }
        acceptAIConsentIfShown()
        let field = app.textFields.firstMatch
        guard tap(field, "coach input") else {
            shot("\(tag)-coach-noinput")
            return
        }
        field.typeText(language == .de ? "Wie habe ich diese Woche geschlafen?" : "How did I sleep this week?")
        for label in ["Send question", "Frage senden"] where app.buttons[label].exists {
            app.buttons[label].tap()
            break
        }
        settle(4)
        // The keyboard would cover the answer; the title bar takes the tap.
        app.staticTexts.firstMatch.tap()
        settle(1)
        shot("\(tag)-coach-running")
        settle(CoachRSweep.tailWait)
        scrollDown()
        shot("\(tag)-coach-proposal")
        if let link = probe("coach.trail.link") {
            link.tap()
            settle(3)
            scrollDown()
            shot("\(tag)-coach-trail")
        } else {
            note("coach-r: no trail link")
        }
    }

    /// The „Erweitert" link under the Coach card, found by identifier or label.
    private func advancedLink() -> XCUIElement? {
        let link = element("settings.ai.advanced")
        for _ in 0 ..< 6 {
            // Above the tab bar, not under it.
            if link.exists, link.isHittable, link.frame.maxY < app.tabBars.firstMatch.frame.minY { return link }
            app.swipeUp()
            settle(1)
        }
        return link.exists && link.isHittable ? link : nil
    }

    /// The sweep's boot, but the AI consent is accepted instead of declined.
    func bootAcceptingAI(extra: [String]) {
        app = XCUIApplication()
        var arguments = language.launchArguments + [
            "-uitest-phase8", "insightsAccessibility",
            "-uitest-marketing",
            "-uitest-sweep",
            "-hl.healthkit.requestedAt.hermetic-user", "true",
            "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
        ]
        if isXXL {
            arguments += ["-UIPreferredContentSizeCategoryName", xxlCategory]
        }
        if env["HL_SWEEP_APPEARANCE"] == "light" {
            arguments += HermeticAppearance.lightArguments
        }
        app.launchHermeticAndWaitForDashboard(extraArguments: arguments + extra, timeout: 120)
        settle(8)
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable {
            confirm.tap()
            settle(1)
        }
        acceptAIConsentIfShown()
        dismissHealthAuthorization()
    }

    func acceptAIConsentIfShown() {
        // POLISH-C — the Dutch consent sheet says "Accepteren".
        for label in ["Accept", "Akzeptieren", "Accepteren"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(2)
                return
            }
        }
    }
}

enum CoachRSweep {
    /// A little longer than `CoachRFixtures.tailDelay` (12 s) after the shot.
    static let tailWait: TimeInterval = 12
}
