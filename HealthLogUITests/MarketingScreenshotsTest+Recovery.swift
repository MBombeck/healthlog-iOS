import XCTest

/// The Recovery category, its pages and the HRV page, on a WHOOP-shaped
/// account (`-uitest-recovery`, see `RecoveryFixtures`). Raw frames for the
/// before-and-after review, not App Store motifs. Soft like the rest of this
/// capture run: a missing surface logs and skips.
///
/// ```sh
/// TEST_RUNNER_HL_MARKETING_LANG=de TEST_RUNNER_HL_MARKETING_TAG=b3-after \
///   scripts/run-serialized-xcode-gate.sh b3 -- test \
///   -only-testing:HealthLogUITests/MarketingScreenshotsTest/test_capture_recovery_pages
/// ```
///
/// Output: `/tmp/marketing-shots-<lang>-<tag>/`.
extension MarketingScreenshotsTest {
    func test_capture_recovery_pages() {
        let app = bootMarketingApp(extraArguments: ["-uitest-recovery"])
        settle(6)
        let insightsTab = app.buttons["Insights"]
        guard insightsTab.waitForExistence(timeout: 10) else {
            logSkip("Insights tab not reachable")
            return
        }
        insightsTab.tap()
        _ = app.staticTexts["insights.page.header.title.overview"].waitForExistence(timeout: 20)
        settle(3)

        // The old recovery address opens the first page of the category.
        openDeepLink("healthlog://insights/recovery")
        settle(6)
        alignInsightsPage(app: app, identifier: "insights.page.recoveryScore")
        capture(name: "recovery")
        app.swipeUp()
        settle(2)
        capture(name: "recovery-end")
        app.swipeDown()
        settle(1)
        captureInfoSheet(app: app, identifier: "insights.metric.info.recoveryScore", shot: "recovery-info")

        // The rest of the category, one swipe each, every page to its end.
        for (kind, shot) in [
            ("dayStrain", "recovery-strain"),
            ("averageHeartRate", "recovery-avghr"),
            ("energyExpenditureKJ", "recovery-energy")
        ] {
            guard swipeToInsightsPage(app: app, identifier: "insights.page.\(kind)") else {
                logSkip("insights.page.\(kind) not reached, \(shot) not captured")
                continue
            }
            capture(name: shot)
            app.swipeUp()
            settle(2)
            capture(name: "\(shot)-end")
            app.swipeDown()
            settle(1)
        }

        openDeepLink("healthlog://insights/hrv")
        settle(6)
        alignInsightsPage(app: app, identifier: "insights.page.hrv")
        capture(name: "hrv")
        captureInfoSheet(app: app, identifier: "insights.metric.info.hrvRMSSD", shot: "hrv-info")
        app.swipeUp()
        settle(2)
        capture(name: "hrv-end")
    }

    /// Opens a page's (i), captures the sheet (top and, after one swipe, its
    /// rest) and closes it with "Fertig"/"Done" or a swipe.
    private func captureInfoSheet(app: XCUIApplication, identifier: String, shot: String) {
        let info = app.buttons[identifier]
        guard info.waitForExistence(timeout: 4), info.isHittable else {
            logSkip("\(identifier) not on screen, \(shot) not captured")
            return
        }
        info.tap()
        settle(3)
        capture(name: shot)
        app.swipeUp()
        settle(1.5)
        capture(name: "\(shot)-end")
        let done = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Done", "Fertig")).firstMatch
        if done.waitForExistence(timeout: 2), done.isHittable {
            done.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        settle(2)
    }

    /// Pages forward over the title until the page `identifier` stands, at
    /// most eight pages. A drag over the title never meets a chart.
    func swipeToInsightsPage(app: XCUIApplication, identifier: String) -> Bool {
        let window = app.windows.firstMatch
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1))
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
        for _ in 0 ..< 8 {
            let page = app.scrollViews.matching(identifier: identifier).firstMatch
            if page.exists, abs(page.frame.minX) < 50 { return true }
            right.press(forDuration: 0.05, thenDragTo: left)
            settle(2)
        }
        let page = app.scrollViews.matching(identifier: identifier).firstMatch
        return page.exists && abs(page.frame.minX) < 50
    }
}
