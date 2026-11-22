import XCTest

/// **One ordinary tap on "Zeitleiste" at the foot of the Insights overview
/// opens the timeline.**
///
/// On a device the row took several taps or a long press, and the page came
/// up five to ten seconds later. The row sits on the overview page inside the
/// horizontal pager; the test scrolls down to it, taps it once at its centre
/// (without the wait for an idle app a plain `tap()` makes, which would hide
/// a busy main thread) and allows only as long as a push takes. The budget
/// holds the test's own overhead (about two seconds of queries and idle
/// waits on a simulator); the device bug took five to ten.
///
/// World: the hermetic boot with the timeline fixture server (1.47.1, the
/// module on).
@MainActor
final class InsightsTimelineEntryUITests: XCTestCase {
    private var app = XCUIApplication()

    /// How long the timeline may take to appear after the tap, the test's
    /// own overhead included.
    private static let openBudget: TimeInterval = 4

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The overview has settled: scroll to the row, tap once.
    func test_singleTapOpensTimeline() {
        boot()
        openInsights(settleFor: 5)
        tapEntryOnceAndExpectTimeline(label: "settled")
    }

    /// Back from the timeline (its X on a phone), the row opens it again
    /// with one tap, every time.
    func test_singleTapOpensTimelineAgainAfterClosing() {
        boot()
        openInsights(settleFor: 2)
        for round in 1 ... 3 {
            tapEntryOnceAndExpectTimeline(label: "round-\(round)")
            leaveTimeline(label: "round-\(round)")
            XCTAssertTrue(
                element("insights.page.overview").waitForExistence(timeout: 10),
                "[round-\(round)] the overview did not come back"
            )
        }
    }

    /// The full world (every Insights page a real account holds: mood,
    /// medications, workouts, the metric pages), straight after launch while
    /// the overview still loads its cards.
    func test_singleTapOpensTimelineInFullWorldWhileLoading() {
        boot(fullWorld: true)
        openInsights(settleFor: 0)
        tapEntryOnceAndExpectTimeline(label: "full-loading")
    }

    // MARK: - Helpers

    private func boot(fullWorld: Bool = false) {
        app = XCUIApplication()
        let world = fullWorld
            ? [
                "-AppleLanguages",
                "(de)",
                "-AppleLocale",
                "de_DE",
                "-uitest-phase8",
                "insightsAccessibility",
                "-uitest-marketing",
                "-uitest-sweep"
            ]
            : []
        app.launchHermeticAndWaitForDashboard(
            extraArguments: world + [
                "-uitest-timeline",
                "-hl.healthkit.serverVersion", "1.47.1",
                "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
                "-hl.healthkit.waistReadRequested.hermetic-user", "true",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        guard fullWorld else { return }
        // The sweep world may ask about analytics first.
        for label in ["Decline", "Ablehnen"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3), button.isHittable { button.tap() }
        }
    }

    private func openInsights(settleFor seconds: TimeInterval) {
        XCTAssertTrue(ShellNavigator.select(symbol: "sparkles", in: app, timeout: 10), "no Insights tab")
        XCTAssertTrue(
            element("insights.page.overview").waitForExistence(timeout: 30),
            "the Insights overview did not open"
        )
        if seconds > 0 { pause(seconds) }
    }

    /// Scrolls the overview until the row is hittable, taps it once and
    /// measures how long the timeline takes to appear.
    private func tapEntryOnceAndExpectTimeline(label: String) {
        let entry = app.buttons["insights.timeline.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "[\(label)] the timeline row is missing")
        let window = app.windows.firstMatch
        for _ in 0 ..< 12 where !isWellInside(entry, window: window) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.75))
                .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.3)))
        }
        XCTAssertTrue(isWellInside(entry, window: window), "[\(label)] the timeline row never came on screen")
        // Let the scroll come to rest, so the tap is a tap and not a stop.
        pause(1.5)

        let screen = element("timeline.screen")
        XCTAssertFalse(screen.exists, "[\(label)] the timeline was open before the tap")
        // One tap at the row's own centre, without waiting for the app to
        // go idle first: that wait would hide a busy main thread.
        let started = Date()
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let tapped = Date().timeIntervalSince(started)
        let appeared = screen.waitForExistence(timeout: 15)
        let elapsed = Date().timeIntervalSince(started)
        let note = String(format: "[%@] tap took %.2f s, timeline after %.2f s", label, tapped, elapsed)
        print("Z1-TIMING \(note)")
        XCTContext.runActivity(named: note) { _ in }
        XCTAssertTrue(appeared, "[\(label)] one tap did not open the timeline within 15 s")
        XCTAssertLessThan(elapsed, Self.openBudget, "[\(label)] one tap opened the timeline too late: \(note)")
    }

    /// The timeline's full screen (iOS 27 phone) has its X, which leaves the
    /// page under it too; without the full screen the bar's back button.
    private func leaveTimeline(label: String) {
        let close = app.buttons["timeline.across.close"]
        // Held across, the bar steps aside after a rest; a touch brings it back.
        if close.waitForExistence(timeout: 2) || app.revealTimelineControls() {
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(2)
            let stayed = element("timeline.screen").exists
            print("Z1-TIMING [\(label)] after the X the timeline page \(stayed ? "stayed" : "left")")
            XCTAssertFalse(stayed, "[\(label)] the X left the timeline page standing")
        }
        if element("timeline.screen").exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            pause(1.5)
        }
    }

    private func isWellInside(_ element: XCUIElement, window: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let bounds = window.frame
        // Clear of the tab bar at the foot.
        return !frame.isEmpty && frame.minY > bounds.minY + 120 && frame.maxY < bounds.maxY - 110
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
