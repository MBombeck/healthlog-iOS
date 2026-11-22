import XCTest

/// **Insights paging and scrolling, in phases a host trace can frame.**
///
/// An on-request probe, not a gate. It pages sideways through five metric
/// pages and back, then scrolls the page it rests on down and up. Before
/// each phase it writes `<phase>.ready` into the folder that
/// `HL_TRACE_DIR` names (set as `TEST_RUNNER_HL_TRACE_DIR`) and waits for
/// the host to answer with `<phase>.go`, so a host script can attach
/// Instruments to the app and read the app's request log for exactly the
/// gesture. After the phase it writes `<phase>.done`. Without the variable
/// the phases run straight through.
///
/// Only identifiers and helpers that exist in 1.6.0 (310) are used, so the
/// same file measures both builds.
@MainActor
final class InsightsPagingTraceProbeTest: XCTestCase {
    private var app = XCUIApplication()

    /// Page changes in the paging phase: four forward, four back.
    static let pageChanges = 8

    /// Where the sideways drags run, as a share of the window height.
    static let swipeHeight: CGFloat = 0.23

    private nonisolated var traceDirectory: String {
        ProcessInfo.processInfo.environment["HL_TRACE_DIR"] ?? ""
    }

    /// Further launch arguments from `HL_EXTRA_ARGS` (set as
    /// `TEST_RUNNER_HL_EXTRA_ARGS`), separated by spaces, so one build can be
    /// measured with a debug switch on and off.
    private nonisolated var extraLaunchArguments: [String] {
        (ProcessInfo.processInfo.environment["HL_EXTRA_ARGS"] ?? "")
            .split(separator: " ").map(String.init)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_pagingAndScrolling() {
        bootToWeightPage()
        // Visit the pages once, so the measured pass meets pages whose data
        // is already there, the case Alex describes.
        swipe(forward: true, times: 4)
        swipe(forward: false, times: 4)
        settle(4)

        phase("paging") {
            swipe(forward: true, times: Self.pageChanges / 2)
            swipe(forward: false, times: Self.pageChanges / 2)
        }
        settle(2)
        phase("scrolling") {
            let window = app.windows.firstMatch
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25))
            for _ in 0 ..< 3 {
                low.press(forDuration: 0.01, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
                settle(1.2)
            }
            for _ in 0 ..< 3 {
                high.press(forDuration: 0.01, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
                settle(1.2)
            }
        }
        XCTAssertTrue(element("insights.pager").exists, "the pager left the screen during the probe")
    }

    /// The same paging as numbers: the app's CPU work for four pages
    /// forward and four back, three times.
    func test_pagingMetrics() {
        bootToWeightPage()
        swipe(forward: true, times: 4)
        swipe(forward: false, times: 4)
        settle(3)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            swipe(forward: true, times: Self.pageChanges / 2)
            swipe(forward: false, times: Self.pageChanges / 2)
        }
        XCTAssertTrue(element("insights.pager").exists, "the pager left the screen during the measurement")
    }

    /// Scrolling the weight page down and up as numbers, three times.
    func test_scrollingMetrics() {
        bootToWeightPage()
        settle(3)
        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            // Down twice, then up twice, stopping short of a pull at the top.
            for _ in 0 ..< 2 {
                low.press(forDuration: 0.01, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
                settle(1.2)
            }
            for _ in 0 ..< 2 {
                high.press(forDuration: 0.01, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0)
                settle(1.2)
            }
        }
        XCTAssertTrue(element("insights.pager").exists, "the pager left the screen during the measurement")
    }

    // MARK: - Helpers

    private func bootToWeightPage() {
        app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
                "-uitest-phase8", "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ] + extraLaunchArguments,
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
        let tab = app.tabBars.buttons.containing(.image, identifier: "sparkles").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Insights tab")
        tab.tap()
        XCTAssertTrue(
            element("insights.page.header.title.overview").waitForExistence(timeout: 30),
            "the Insights overview did not open"
        )
        settle(4)
        if let url = URL(string: "healthlog://insights/weight") {
            XCUIDevice.shared.system.open(url)
        }
        XCTAssertTrue(element("insights.page.weight").waitForExistence(timeout: 30), "the weight page did not open")
    }

    /// Sideways over the head of the page, where no chart takes the drag as
    /// a scrub and, in 1.5, the strip pinned at the top does not take it
    /// either (at a tenth of the height it scrolled the 1.5 strip instead
    /// of the pager).
    private func swipe(forward: Bool, times: Int) {
        let window = app.windows.firstMatch
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: Self.swipeHeight))
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: Self.swipeHeight))
        for _ in 0 ..< times {
            if forward {
                right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            } else {
                left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            }
            settle(1.2)
        }
    }

    private func phase(_ name: String, _ body: () -> Void) {
        let directory = traceDirectory
        guard !directory.isEmpty else {
            body()
            return
        }
        let base = URL(fileURLWithPath: directory).appendingPathComponent(name)
        FileManager.default.createFile(atPath: base.path + ".ready", contents: Data())
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: base.path + ".go"), Date() < deadline {
            settle(0.25)
        }
        body()
        settle(1)
        FileManager.default.createFile(atPath: base.path + ".done", contents: Data())
        // The host stops its recording; give it time before the next phase.
        settle(8)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
