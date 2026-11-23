import XCTest

/// Held across, the timeline's bar at the top (the X, the period and the
/// menu of lines and lanes) fades after a rest and a touch brings it back
/// (`TimelineChromeState`). A test that wants one of those controls asks for
/// them first.
extension XCUIApplication {
    /// Brings the timeline's bar back if it stepped aside, with a tap in the
    /// column of names, which picks no moment. Returns whether `identifier`
    /// is on screen afterwards.
    @discardableResult
    func revealTimelineControls(waitingFor identifier: String = "timeline.across.close", timeout: TimeInterval = 3) -> Bool {
        let control = descendants(matching: .any)[identifier]
        if control.exists { return true }
        // The board's own left edge: the column of names on the full board,
        // never the sidebar or a control beside the page.
        let board = descendants(matching: .any).matching(identifier: "timeline.board").allElementsBoundByIndex
            .last { !$0.frame.isEmpty }
        guard let board else { return false }
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        return control.waitForExistence(timeout: timeout)
    }
}
