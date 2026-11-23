import XCTest

/// **How smoothly Insights pages sideways and scrolls down, as numbers.**
///
/// An on-request measurement, not a gate: the hitch numbers of a shared
/// simulator only mean something next to the same test run against another
/// build on the same simulator. It stays out of the release run.
///
/// World: the hermetic sweep boot with the marketing fixture (recovery family,
/// heart pages, every chart block), German, so the pager holds the pages a
/// real account holds.
///
/// On the simulator only the scroll duration and the app's CPU work come
/// back; the hitch numbers need a device.
///
/// Both cases drag where no chart sits: sideways over the page title, down
/// and up in the right gutter, so a chart never takes a drag as a scrub.
@MainActor
final class InsightsScrollPerformanceUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Paging sideways: three pages forward, three back, per iteration,
    /// from Gewicht, so the pages passed are the same metric pages on
    /// every build (the block before it changed with the recovery category).
    func test_01_pagingSideways() {
        boot()
        openInsights()
        open("healthlog://insights/weight")
        XCTAssertTrue(
            element("insights.page.weight").waitForExistence(timeout: 30),
            "the weight page did not open"
        )
        settle(5)
        let window = app.windows.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: metrics, options: options) {
            let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1))
            let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
            for _ in 0 ..< 3 {
                right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
                settle(0.8)
            }
            for _ in 0 ..< 3 {
                left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
                settle(0.8)
            }
        }
        XCTAssertTrue(element("insights.pager").exists, "the pager left the screen during the measurement")
    }

    /// Scrolling a heavy metric page down past the strip and back up, so the
    /// strip pins and unpins once per direction.
    func test_02_scrollingMetricPage() {
        boot()
        openInsights()
        open("healthlog://insights/pulse")
        XCTAssertTrue(
            element("insights.page.pulse").waitForExistence(timeout: 30),
            "the pulse page did not open"
        )
        settle(5)
        measureVerticalScroll()
    }

    /// Scrolling the overview down past the strip and back up.
    func test_03_scrollingOverview() {
        boot()
        openInsights()
        measureVerticalScroll()
        XCTAssertTrue(element("insights.page.overview").exists, "the overview left the screen during the measurement")
    }

    // MARK: - Helpers

    /// The scroll signposts, and the app's own CPU work during the gesture.
    /// The simulator reports no hitch numbers; the instructions the app
    /// retires for the same gesture barely depend on the machine's load, so
    /// they carry the comparison there.
    private var metrics: [any XCTMetric] {
        [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)]
    }

    private func boot() {
        app = XCUIApplication()
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        settle(6)
        for label in ["Decline", "Ablehnen"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(1)
            }
        }
    }

    private func openInsights() {
        XCTAssertTrue(ShellNavigator.select(symbol: "sparkles", in: app, timeout: 10), "no Insights tab")
        XCTAssertTrue(
            element("insights.page.header.title.overview").waitForExistence(timeout: 30),
            "the Insights overview did not open"
        )
        settle(5)
    }

    private func measureVerticalScroll() {
        let window = app.windows.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: metrics, options: options) {
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25))
            low.press(forDuration: 0.01, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
            settle(1.5)
            high.press(forDuration: 0.01, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
            settle(1.5)
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
