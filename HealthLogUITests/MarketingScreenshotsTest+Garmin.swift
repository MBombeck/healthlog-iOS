import XCTest

/// The Recovery category of an account with Garmin data (server v1.47).
///
/// Boots the recovery overlay and, unless `TEST_RUNNER_HL_GARMIN_OVERLAY=0`,
/// adds Garmin's four types to it (`-uitest-garmin`). The run without the
/// overlay is the "before" picture: a build that does not know the types shows
/// no Garmin page in the category, because the types never reach the family.
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
        alignInsightsPage(app: app, identifier: "insights.page.recoveryScore")
        capture(name: "garmin-recovery")
        guard withGarmin else { return }
        guard swipeToInsightsPage(app: app, identifier: "insights.page.bodyBattery") else {
            logSkip("Body Battery page not reached")
            return
        }
        capture(name: "garmin-bodybattery")
        app.swipeUp()
        settle(2)
        capture(name: "garmin-bodybattery-end")
    }
}
