import XCTest

/// **PERF (1.5) — the same measurements on two builds, for a side-by-side table.**
///
/// Not a gate and not a budget, like `LaunchPerformanceProbeTest`: the numbers
/// only mean something next to the same probe run against another build on the
/// same simulator, interleaved, under the same load. The class skips unless
/// `TEST_RUNNER_HL_PERF_OUT` names a host file the samples are appended to.
///
/// World: the hermetic sweep boot (`-uitest-marketing`, `-uitest-sweep`, three
/// medications, readings for the metric pages) against a 1.47 server with the
/// lab line on the weight page (`-uitest-lab-lines`; a build without that
/// overlay ignores the argument and shows the page without it). Only
/// identifiers that exist in 1.4.0 and 1.5 are waited on, so the probe file is
/// byte-identical on both builds.
///
/// Wall-clock values carry XCUITest's own query overhead; it is the same on
/// both builds and cancels out in a comparison.
@MainActor
final class PerfComparisonProbeTest: XCTestCase {
    private nonisolated var outputFile: String {
        ProcessInfo.processInfo.environment["HL_PERF_OUT"] ?? ""
    }

    private let arguments = [
        "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
        "-uitest-hermetic", "-uitest-ack-disclaimer", "-uitest-disable-biometric-lock",
        "-uitest-phase8", "insightsAccessibility",
        "-uitest-marketing",
        "-uitest-sweep",
        "-uitest-lab-lines",
        "-hl.healthkit.serverVersion", "1.47.0",
        "-insights.labOverlay.weight", "lab:bm_hba1c",
        "-hl.healthkit.requestedAt.hermetic-user", "true",
        "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
    ]

    private var app = XCUIApplication()

    override func setUpWithError() throws {
        let missing = outputFile.isEmpty
        try XCTSkipIf(missing, "HL_PERF_OUT not set — the comparison probe only runs on request")
        continueAfterFailure = true
    }

    // MARK: - 1. Launch

    /// A new process each iteration, until the app is responsive.
    func test_01_coldLaunchMetric() {
        app.launchArguments = arguments
        app.launch()
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            app.terminate()
        }
    }

    /// Cold: launch until the Dashboard greeting exists. Warm: back from the
    /// home screen until the greeting is hittable again.
    func test_02_firstContentColdAndWarm() {
        app.launchArguments = arguments
        app.launch()
        app.terminate()
        for iteration in 1 ... 3 {
            let start = Date()
            app.launch()
            guard greeting.waitForExistence(timeout: 60) else {
                record("iteration=\(iteration) cold_first_content=timeout")
                app.terminate()
                continue
            }
            let cold = Date().timeIntervalSince(start)
            settle(4)
            XCUIDevice.shared.press(.home)
            settle(3)
            let resume = Date()
            app.activate()
            let warm = waitHittable(greeting, 30) ? Date().timeIntervalSince(resume) : -1
            record(String(format: "iteration=%d cold_first_content_ms=%.0f warm_resume_ms=%.0f", iteration, cold * 1000, warm * 1000))
            app.terminate()
            settle(2)
        }
    }

    // MARK: - 2. Time to content

    func test_03_timeToContent() {
        for iteration in 1 ... 2 {
            boot()
            let insights = timeTab("sparkles", until: element("insights.page.header.title.overview"))
            settle(3)
            let meds = timeTab("pills.fill", until: element("medications.card.mkshot-med-trulicity"))
            settle(3)
            let today = timeTab("house.fill", until: greeting)
            settle(3)
            let start = Date()
            open("healthlog://insights/weight")
            let metric = element("insights.metric.rangeDelta").waitForExistence(timeout: 30) ? Date().timeIntervalSince(start) : -1
            settle(4)
            let labLine = element("insights.labOverlay.chart").exists ? 1 : 0
            record(String(
                format: "iteration=%d insights_ms=%.0f meds_ms=%.0f today_ms=%.0f metric_ms=%.0f lab_line=%d",
                iteration, insights * 1000, meds * 1000, today * 1000, metric * 1000, labLine
            ))
            app.terminate()
            settle(2)
        }
    }

    // MARK: - 2. Scrolling (hitch rate)

    func test_04_scrollToday() {
        boot()
        measureScroll()
    }

    func test_05_scrollInsights() {
        boot()
        _ = timeTab("sparkles", until: element("insights.page.header.title.overview"))
        settle(4)
        measureScroll()
    }

    func test_06_scrollMeds() {
        boot()
        _ = timeTab("pills.fill", until: element("medications.card.mkshot-med-trulicity"))
        settle(4)
        measureScroll()
    }

    func test_07_scrollMetricWithLabLine() {
        boot()
        open("healthlog://insights/weight")
        _ = element("insights.metric.rangeDelta").waitForExistence(timeout: 30)
        settle(5)
        measureScroll()
    }

    // MARK: - 3. Memory after ten screen changes

    func test_08_memoryAfterTenSwitches() {
        boot()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            startMeasuring()
            for symbol in [
                "pills.fill",
                "sparkles",
                "ellipsis",
                "house.fill",
                "pills.fill",
                "sparkles",
                "ellipsis",
                "house.fill",
                "sparkles",
                "house.fill"
            ] {
                let button = app.tabBars.buttons.containing(.image, identifier: symbol).firstMatch
                if button.waitForExistence(timeout: 10) { button.tap() }
                settle(1.5)
            }
            stopMeasuring()
        }
    }

    // MARK: - 4. Requests while Today opens

    /// The host reads the hermetic request trace (`hl.perf`) between the two
    /// stamps this case writes.
    func test_09_requestsOpeningToday() {
        app.launchArguments = arguments
        app.launch()
        app.terminate()
        settle(2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()
        app.launch()
        _ = greeting.waitForExistence(timeout: 60)
        settle(12)
        record("requests_window start=\(formatter.string(from: start)) end=\(formatter.string(from: Date()))")
        app.terminate()
    }

    // MARK: - Helpers

    private var greeting: XCUIElement {
        app.staticTexts["dashboard.greeting"]
    }

    private func boot() {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        _ = greeting.waitForExistence(timeout: 120)
        settle(6)
        for label in ["Decline", "Ablehnen"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable { button.tap()
                settle(1)
            }
        }
    }

    private func measureScroll() {
        let window = app.windows.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            // The right gutter: a chart under the middle would take the drag as a scrub.
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25))
            low.press(forDuration: 0.01, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
            settle(1.5)
            high.press(forDuration: 0.01, thenDragTo: low, withVelocity: .fast, thenHoldForDuration: 0)
            settle(1.5)
        }
    }

    private func timeTab(_ symbol: String, until target: XCUIElement) -> TimeInterval {
        let button = app.tabBars.buttons.containing(.image, identifier: symbol).firstMatch
        guard button.waitForExistence(timeout: 10) else { return -1 }
        let start = Date()
        button.tap()
        return target.waitForExistence(timeout: 30) ? Date().timeIntervalSince(start) : -1
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitHittable(_ target: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists, target.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func record(_ line: String) {
        let url = URL(fileURLWithPath: outputFile)
        let data = Data((name + " " + line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
