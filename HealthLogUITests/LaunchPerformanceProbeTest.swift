import XCTest

/// **H2 (1.1.0) — a launch-time probe for comparing two builds.**
///
/// Not a gate and not a budget: the simulator is not a phone, and the numbers
/// are only meaningful next to the same probe run against another build on the
/// same simulator, in the same hour, under the same load. The class skips unless
/// `TEST_RUNNER_HL_PERF_OUT` names a host file the samples are appended to.
///
/// Three measurements, each on the hermetic boot (network-free, same fixtures):
/// - `XCTApplicationLaunchMetric` — cold launch until the app is responsive.
/// - launch → the Dashboard greeting exists (first Dashboard content).
/// - Insights tab tap → the overview page header exists (first Insights content).
///
/// The last two are wall clock around XCUITest's own polling, so they carry a
/// constant query overhead of their own; it cancels out in a comparison.
@MainActor
final class LaunchPerformanceProbeTest: XCTestCase {
    private nonisolated var outputFile: String {
        ProcessInfo.processInfo.environment["HL_PERF_OUT"] ?? ""
    }

    private let arguments = [
        "-uitest-hermetic", "-uitest-ack-disclaimer", "-uitest-disable-biometric-lock",
        "-uitest-phase8", "insightsAccessibility",
        "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
        "-hl.healthkit.requestedAt.hermetic-user", "true",
        "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
    ]

    override func setUpWithError() throws {
        let missing = outputFile.isEmpty
        try XCTSkipIf(missing, "HL_PERF_OUT not set — the launch probe only runs on request")
    }

    func test_coldLaunchMetric() {
        let app = XCUIApplication()
        app.launchArguments = arguments
        // Warm the install once so the first measured iteration is not the
        // one-time post-install work.
        app.launch()
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            app.terminate()
        }
    }

    func test_dashboardAndInsightsFirstContent() {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        app.terminate()
        for iteration in 1 ... 5 {
            let launchStart = Date()
            app.launch()
            let greeting = app.staticTexts["dashboard.greeting"]
            guard greeting.waitForExistence(timeout: 60) else {
                record("iteration=\(iteration) dashboard=timeout")
                app.terminate()
                continue
            }
            let dashboard = Date().timeIntervalSince(launchStart)
            let insightsTab = app.tabBars.buttons.containing(.image, identifier: "sparkles").firstMatch
            _ = insightsTab.waitForExistence(timeout: 10)
            // Let launch work settle so the tab switch is measured on its own.
            Thread.sleep(forTimeInterval: 3)
            let tapStart = Date()
            insightsTab.tap()
            let header = app.staticTexts["insights.page.header.title.overview"]
            let insights = header.waitForExistence(timeout: 30) ? Date().timeIntervalSince(tapStart) : -1
            record(String(format: "iteration=%d dashboard_ms=%.0f insights_ms=%.0f", iteration, dashboard * 1000, insights * 1000))
            app.terminate()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func record(_ line: String) {
        let url = URL(fileURLWithPath: outputFile)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
