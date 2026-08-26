import XCTest

/// W5a (v0.12) — captures the Insights **overview** (de-duped Vitals + Targets,
/// no MoodSummary/BMI duplication) and a **per-metric page** (inline editorial
/// assessment + period-over-period delta) on the live demo tenant, so the
/// operator can SEE the entry-page polish without walking the app. Screenshots
/// land as `XCTAttachment`s on the result bundle (`xcresult`); a post-step
/// extracts them to `.planning/v012-megamarathon/W5a-screens/`.
///
/// Reuses the same `demo.healthlog.dev` onboarding walk as
/// `WalkthroughDashboardTest`, short-circuited when already authenticated.
@MainActor
final class InsightsW5aWalkthroughTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_capture_insights_overview_and_metric_page() {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot.
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)
        Thread.sleep(forTimeInterval: 2)

        // Navigate to the Insights tab. The tab title is localised ("Insights"
        // in both EN + DE).
        let insightsTab = app.buttons["Insights"]
        XCTAssertTrue(insightsTab.waitForExistence(timeout: 10), "Insights tab button missing")
        insightsTab.tap()

        // Let the overview fan out (vitals + targets + long-tail). v0.14 DRIFT-2 —
        // the overview header routes through the unified `InsightsPageHeader`, so
        // the title identifier is now `insights.page.header.title.overview`.
        let header = app.staticTexts["insights.page.header.title.overview"]
        let headerAppeared = header.waitForExistence(timeout: 20)
        if !headerAppeared { attachFailureDiagnostics(app: app, label: "overview-header-missing") }
        XCTAssertTrue(headerAppeared, "Insights overview header missing")
        Thread.sleep(forTimeInterval: 5)

        attach(app: app, name: "insights-overview")

        // Scroll once to capture the Targets + long-tail region too.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        attach(app: app, name: "insights-overview-scrolled")

        // Scroll back up and open a metric page. Prefer the resting-HR / weight
        // target tile (the metrics that USED to double-render) so the operator
        // sees the de-dupe + the new inline assessment + delta on one page.
        app.swipeDown()
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1)

        let metricTile = firstExistingTile(app: app, identifiers: [
            "insights.tile.WEIGHT",
            "insights.tile.RESTING_HR",
            "insights.tile.PULSE",
            "insights.vital.hrv",
            "insights.vital.weight"
        ])
        if let metricTile {
            metricTile.tap()
            Thread.sleep(forTimeInterval: 5)
            attach(app: app, name: "insights-metric-page")
            // Scroll down to surface the assessment prose + delta below the chart.
            app.swipeUp()
            Thread.sleep(forTimeInterval: 2)
            attach(app: app, name: "insights-metric-page-scrolled")
        } else {
            let miss = XCTAttachment(string: "No tappable insights metric tile found in tree")
            miss.name = "insights-metric-tile-absent"
            miss.lifetime = .keepAlways
            add(miss)
        }
    }

    // MARK: - Helpers

    private func attach(app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func firstExistingTile(app: XCUIApplication, identifiers: [String]) -> XCUIElement? {
        for _ in 0 ..< 6 {
            for id in identifiers {
                let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
                if el.exists, el.isHittable { return el }
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
