import XCTest

/// 1.4 B3 — the recovery page, the details behind its cards and the HRV page,
/// on a WHOOP-shaped account (`-uitest-recovery`, see `RecoveryFixtures`).
/// Raw frames for the before-and-after review, not App Store motifs. Soft like
/// the rest of this capture run: a missing surface logs and skips.
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

        openDeepLink("healthlog://insights/recovery")
        settle(6)
        alignInsightsPage(app: app, identifier: "insights.page.recovery")
        capture(name: "recovery")
        app.swipeUp()
        settle(2)
        capture(name: "recovery-end")
        app.swipeDown()
        settle(1)
        // 1.4 B4 — the page's (i), where the guide and the references went.
        captureInfoSheet(app: app, identifier: "insights.recovery.info", shot: "recovery-info")

        // The details behind the cards; only the rebuilt page has them. 1.4 B4
        // photographs them to their charts (date axis, 30-day card, units)
        // and adds the longest title on the page.
        captureRecoveryDetail(app: app, identifier: "insights.recovery.trend.recoveryScore", shot: "recovery-score-detail")
        captureRecoveryDetail(app: app, identifier: "insights.recovery.trend.dayStrain", shot: "recovery-strain-detail", toEnd: true)
        captureRecoveryDetail(app: app, identifier: "insights.recovery.row.averageHeartRate", shot: "recovery-avghr-detail")
        captureRecoveryDetail(
            app: app,
            identifier: "insights.recovery.row.energyExpenditureKJ",
            shot: "recovery-energy-detail",
            toEnd: true
        )

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

    /// Taps a recovery card or row, captures what it opened, and goes back the
    /// way a person would: the navigation bar's back button. Its absence is
    /// recorded, because a pushed page without one is a dead end.
    private func captureRecoveryDetail(app: XCUIApplication, identifier: String, shot: String, toEnd: Bool = false) {
        let target = app.descendants(matching: .any)[identifier]
        guard target.waitForExistence(timeout: 4), target.isHittable else {
            logSkip("\(identifier) not on screen, \(shot) not captured")
            return
        }
        target.tap()
        settle(4)
        capture(name: shot)
        if toEnd {
            app.swipeUp()
            settle(2)
            capture(name: "\(shot)-end")
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 2), back.isHittable {
            back.tap()
        } else {
            logSkip("\(shot): no back button in the navigation bar")
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        settle(2)
    }
}
