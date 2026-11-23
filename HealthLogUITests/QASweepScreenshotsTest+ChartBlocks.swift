import XCTest

/// The chart, header and glass blocks (``HLChartBlocksGallery``) and the
/// reference metric page under a resting finger, in the dark and the light
/// appearance of one run.
///
/// A scrub callout only stands while the finger is down, and XCTest takes no
/// picture during a press. So the test drops a request file
/// (`_scrub-request-<name>`) into the output directory and holds the press;
/// the host takes the picture of the simulator meanwhile
/// (`xcrun simctl io <device> screenshot`, see the package report). Without
/// a host watcher the request stays and the press simply ends.
extension QASweepScreenshotsTest {
    /// The chart block page from top to end and its info sheet, then the
    /// Puls page scrubbed, each dark and light.
    func test_32_chartBlocks() {
        scrollColumn = 0.97 // Past the chart's scrub.
        for (look, arguments) in [("dark", [String]()), ("light", HermeticAppearance.lightArguments)] {
            bootChartBlocks(extra: arguments)
            shotToEnd("32-chartblocks-\(look)")
            scrollUpToTop()
            if tap(element("chartBlocks.info"), "chart blocks info") {
                settle(2.5)
                shot("32-chartblocks-info-\(look)")
                if !tap(element("hl.sheet.close"), "info close") { dismissSheet() }
                settle(1.5)
            }
            boot(extra: arguments)
            openDeepLink("healthlog://insights/pulse")
            settle(6)
            shot("32-pulse-\(look)")
            scrubAndRequestPicture("32-pulse-scrub-\(look)", at: CGVector(dx: 0.55, dy: 0.6))
        }
    }

    /// Launches with the chart block page in place of the root.
    func bootChartBlocks(extra: [String]) {
        app = XCUIApplication()
        var arguments = language.launchArguments + [
            "-uitest-hermetic",
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock",
            "-uitest-chart-blocks"
        ] + extra
        if isXXL {
            arguments += ["-UIPreferredContentSizeCategoryName", xxlCategory]
        }
        app.launchArguments = arguments
        app.launch()
        waitFor("chartBlocks.ready", 60)
        settle(2)
    }

    /// Long-presses the chart at `point` (normalized window coordinates),
    /// moves a little so the selection follows, and holds while the host
    /// photographs the screen on the request file's word.
    func scrubAndRequestPicture(_ name: String, at point: CGVector) {
        let request = URL(fileURLWithPath: outputDir).appendingPathComponent("_scrub-request-\(name)")
        try? Data(name.utf8).write(to: request)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: point)
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: point.dx + 0.08, dy: point.dy))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: 40, thenHoldForDuration: 12)
        settle(1)
        if FileManager.default.fileExists(atPath: request.path) {
            note("scrub picture \(name): no host watcher answered the request")
            try? FileManager.default.removeItem(at: request)
        }
    }
}
