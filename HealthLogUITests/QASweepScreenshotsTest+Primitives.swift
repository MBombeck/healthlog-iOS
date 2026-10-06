import XCTest

/// H2 — the navigation and capture primitives of ``QASweepScreenshotsTest``,
/// split out so the walk itself stays readable (and inside `type_body_length`).
extension QASweepScreenshotsTest {
    // MARK: - Navigation primitives

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func tab(_ symbol: String) {
        let button = app.tabBars.buttons.containing(.image, identifier: symbol).firstMatch
        if tap(button, "tab \(symbol)") { settle(3) }
    }

    @discardableResult
    func tap(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 8) -> Bool {
        let started = Date()
        guard target.waitForExistence(timeout: timeout) else {
            note("not found: \(what) (waited \(Int(Date().timeIntervalSince(started))) s)")
            return false
        }
        guard target.isHittable else {
            note("not hittable: \(what)")
            return false
        }
        target.tap()
        return true
    }

    func waitFor(_ identifier: String, _ timeout: TimeInterval) {
        let started = Date()
        if !element(identifier).waitForExistence(timeout: timeout) {
            note("timeout \(Int(Date().timeIntervalSince(started))) s waiting for \(identifier)")
        }
    }

    /// Scrolls until `identifier` is hittable, at most eight drags; `nil` when
    /// the element never showed up (an honest "not on this screen").
    func probe(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        for _ in 0 ..< 8 {
            if target.exists, target.isHittable { return target }
            scrollDown()
        }
        return target.exists && target.isHittable ? target : nil
    }

    /// A slow drag with a hold at the end: no momentum, so one call moves the
    /// content by a predictable ~40 % of the screen.
    func scrollDown() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
        settle(1.2)
    }

    func scrollUpToTop() {
        let status = app.statusBars.firstMatch
        if status.exists, status.isHittable {
            status.tap()
        } else {
            for _ in 0 ..< 4 {
                app.swipeDown()
            }
        }
        settle(1)
    }

    func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable {
            back.tap()
        } else {
            let edge = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 300, dy: 0)))
        }
        settle(1.5)
    }

    func dismissSheet() {
        for label in ["Cancel", "Abbrechen", "Close", "Schließen", "Done", "Fertig"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(1.5)
                return
            }
        }
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 700)))
        settle(1.5)
    }

    func openDeepLink(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    func visibleInsightsPage() -> String? {
        let pages = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'insights.page.'"))
        let width = app.windows.firstMatch.frame.width
        for index in 0 ..< pages.count {
            let page = pages.element(boundBy: index)
            let frame = page.frame
            if abs(frame.minX) < width * 0.25, frame.width > width * 0.5 { return page.identifier }
        }
        return nil
    }

    /// The disclaimer ack, the AI-consent gate, any HealthKit sheet.
    func dismissOverlays() {
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.exists, confirm.isHittable { confirm.tap()
            settle(1)
        }
        for label in ["Decline", "Ablehnen"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable { button.tap()
                settle(1)
            }
        }
        dismissHealthAuthorization()
    }

    func dismissHealthAuthorization() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Don't Allow", "Don’t Allow", "Nicht erlauben", "Nicht zulassen"]
        for owner in [app, springboard] {
            for label in labels {
                let button = owner.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    settle(1.5)
                    note("dismissed HealthKit authorization (\(label))")
                    return
                }
            }
        }
    }

    // MARK: - Capture

    func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The screen as it stands, then once more after one scroll.
    func shotPair(_ name: String) {
        shot("\(name)-top")
        scrollDown()
        shot("\(name)-scroll1")
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            note("write failed \(name): \(error)")
        }
        // An alert is a finding: it is in the picture above; name it, then
        // clear it so the walk can go on.
        let alert = app.alerts.firstMatch
        if alert.exists {
            let texts = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            note("ALERT on \(name): \(texts)")
            alert.buttons.firstMatch.tap()
            settle(1)
        }
    }

    func note(_ line: String) {
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("_notes.txt")
        let stamped = "[\(name)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}
