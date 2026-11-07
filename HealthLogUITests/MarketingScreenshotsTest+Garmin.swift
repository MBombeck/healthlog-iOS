import XCTest

/// #162 — the recovery page of an account with Garmin data (server v1.47).
///
/// Boots the recovery overlay and, unless `TEST_RUNNER_HL_GARMIN_OVERLAY=0`,
/// adds Garmin's four types to it (`-uitest-garmin`). The run without the
/// overlay is the "before" picture: a build that does not know the types shows
/// exactly that page, because the rows never reach the recovery list.
extension MarketingScreenshotsTest {
    func test_capture_garmin_recovery() {
        let withGarmin = ProcessInfo.processInfo.environment["HL_GARMIN_OVERLAY"] != "0"
        let app = bootMarketingApp(extraArguments: ["-uitest-recovery"] + (withGarmin ? ["-uitest-garmin"] : []))
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
        capture(name: "garmin-recovery")
        app.swipeUp()
        settle(2)
        capture(name: "garmin-recovery-end")
        guard withGarmin else { return }
        let row = app.descendants(matching: .any)["insights.recovery.row.bodyBattery"]
        guard row.waitForExistence(timeout: 4), row.isHittable else {
            logSkip("Body Battery row not on screen")
            return
        }
        row.tap()
        settle(4)
        capture(name: "garmin-bodybattery-detail")
        app.swipeUp()
        settle(2)
        capture(name: "garmin-bodybattery-detail-end")
    }
}
