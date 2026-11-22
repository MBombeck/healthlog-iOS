import XCTest

/// The timeline against a 1.47.1 server with the module on
/// (`-uitest-timeline`, `TimelineFixtures`): three months as it opens (on a
/// phone with iOS 27 turned across in its full screen), a picked week with
/// its summary, the choice of lines and lanes, a pinch closer, one week,
/// twelve months and everything, and upright again after the X. The chosen lines are the hospital chart's: blood
/// pressure both ways, weight, resting pulse, sleep, two liver values and a
/// headache. Runs with the sweep's language, appearance, text size and
/// display. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_40_timeline() {
        boot(extra: [
            "-uitest-timeline",
            "-hl.healthkit.serverVersion", "1.47.1",
            // The server version above makes a returning user eligible for
            // the read types that joined later; the app asks for them once
            // on a foreground pass, not from the timeline. The sweep's user
            // has answered that sheet already, so it never covers the board.
            "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
            "-hl.healthkit.waistReadRequested.hermetic-user", "true",
            "-timeline.values",
            #"("BLOOD_PRESSURE_SYS","BLOOD_PRESSURE_DIA","WEIGHT","RESTING_HEART_RATE","SLEEP_DURATION","lab:bm_ggt","lab:bm_got","symptom:sd_headache")"#
        ])
        openDeepLink("healthlog://timeline")
        // The X stands from the moment the full screen is up until the bar
        // steps aside after the board's rest.
        let inCover = app.buttons["timeline.across.close"].waitForExistence(timeout: 8)
        settle(3)
        if !app.descendants(matching: .any)["timeline.screen"].exists { note("40: timeline screen not on screen") }
        // A phone on iOS 27 turns itself across for the full board.
        if inCover {
            let frame = app.windows.firstMatch.frame
            if frame.width < frame.height { note("40: the timeline full screen did not turn across") }
            app.revealTimelineControls()
            settle(1)
        }
        shot("40-timeline-top")
        if inCover { photographControlsResting() }

        photographPickAndChoices(inCover: inCover)
        photographZoom(inCover: inCover)
        // The phone's full screen, held upright on purpose: the compact board
        // with its quiet hint. Then the X, and the app stands upright.
        let close = app.buttons["timeline.across.close"]
        if inCover {
            XCUIDevice.shared.orientation = .landscapeLeft
            settle(2)
            XCUIDevice.shared.orientation = .portrait
            settle(3)
            shot("40-timeline-upright")
        }
        if close.exists, close.isHittable {
            close.tap()
            settle(3)
            shot("40-timeline-closed")
        }
        scrollColumn = 0.5
    }

    /// Held across, the bar steps aside after a rest and the board takes
    /// the height; a touch brings it back.
    private func photographControlsResting() {
        settle(4.5)
        if app.buttons["timeline.across.close"].exists { note("40: the bar did not step aside after the rest") }
        shot("40-timeline-controls-resting")
        if !app.revealTimelineControls() { note("40: a touch did not bring the bar back") }
        settle(1)
        shot("40-timeline-controls-back")
    }

    /// A week in the middle of the board, its summary, and the menu of lines and lanes.
    private func photographPickAndChoices(inCover: Bool) {
        // A week in the middle of the board: its summary under the board.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.42)).tap()
        settle(2)
        shot("40-timeline-picked")
        // Upright drags in the name column: over the plot a press and drag
        // picks a moment instead of scrolling the page.
        scrollColumn = Self.timelineNameColumn
        // The page stays under the turned full screen, so the summary is
        // there twice; one of them on screen is enough.
        let summaries = app.descendants(matching: .any).matching(identifier: "timeline.summary")
        for _ in 0 ..< 4 where !summaries.allElementsBoundByIndex.contains(where: isOnScreen) {
            scrollDown()
        }
        if !summaries.allElementsBoundByIndex.contains(where: isOnScreen) {
            note("40: the summary of the picked period is not on screen")
        }
        shot("40-timeline-summary")
        scrollDown()
        shot("40-timeline-summary2")
        scrollColumn = 0.5
        scrollUpToTop()

        // The menu of lines and lanes, by its fixed identifier, in the stack
        // and in the turned full screen alike. Tapped at its own centre: an
        // app that turned itself leaves the test's idea of hittable behind.
        // The page stays under the turned full screen: its menu has its own name there.
        let choicesIdentifier = inCover ? "timeline.across.choices" : "timeline.choices"
        if inCover { app.revealTimelineControls(waitingFor: choicesIdentifier) }
        let choices = app.buttons[choicesIdentifier]
        if choices.waitForExistence(timeout: 5) {
            choices.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            settle(2)
            shot("40-timeline-choices")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
            settle(1.5)
        } else {
            XCTFail("40: the menu of lines and lanes is missing")
        }
    }

    /// A pinch closer, then the quick choices of a week, twelve months and everything.
    private func photographZoom(inCover: Bool) {
        let window = app.windows.firstMatch
        // Two fingers apart over the board: closer than the quick choices.
        window.pinch(withScale: 2.5, velocity: 1.5)
        settle(3)
        shot("40-timeline-pinched")
        if inCover { app.revealTimelineControls() }
        if tapSegment(["1 Woche", "1 week"]) {
            settle(5)
            shot("40-timeline-week")
        } else {
            note("40: week segment not found")
        }
        if inCover { app.revealTimelineControls() }
        if tapSegment(["12 Monate", "12 months", "12 maanden"]) {
            settle(5)
            shot("40-timeline-year")
        } else {
            note("40: twelve months segment not found")
        }
        if inCover { app.revealTimelineControls() }
        if tapSegment(["Alles", "Everything"]) {
            settle(5)
            shot("40-timeline-all")
        } else {
            note("40: everything segment not found")
        }
    }

    /// The timeline before the module is switched on: the explanation and the switch.
    func test_40_timelineModuleOff() {
        boot(extra: ["-hl.healthkit.serverVersion", "1.47.1"])
        openDeepLink("healthlog://timeline")
        settle(5)
        shot("40-timeline-module-off")
    }

    /// Where the board's names stand, as a share of the window's width.
    private static let timelineNameColumn: CGFloat = 0.12

    /// Whether `element` lies inside the window. An app that turned itself
    /// leaves the test's idea of hittable behind, so the frames decide.
    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return !frame.isEmpty && window.contains(CGPoint(x: frame.midX, y: frame.minY + 20))
    }

    /// Taps the first segment or button labelled like one of `labels`, at
    /// its own centre (the turned full screen confuses `isHittable`).
    private func tapSegment(_ labels: [String]) -> Bool {
        for label in labels {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if button.exists {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
        }
        return false
    }
}
