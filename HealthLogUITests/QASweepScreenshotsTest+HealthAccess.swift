import XCTest

/// The Health access sheet of iOS 27 has no "Don't Allow" in its top bar: the
/// answer sits at the end of a long list, out of reach at the largest text
/// size, and the sheet cannot be swiped away. Unanswered, it covers every
/// screen behind it and comes back on each request. Answering it once ends that
/// for the simulator, because Health remembers the answer.
extension QASweepScreenshotsTest {
    private static let sheetTitles = ["Health-Zugriff", "Health Access", "Health-toegang"]
    private static let declineLabels = ["Nicht erlauben", "Don’t Allow", "Don't Allow", "Niet toestaan"]

    /// Answers a Health access sheet if one is up; a no-op otherwise.
    func answerHealthAccess() {
        dismissHealthAuthorization()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard let owner = [app, springboard].first(where: { healthSheetTitle(in: $0) != nil }) else { return }
        for _ in 0 ..< 40 {
            // After "Don't Allow", Health confirms with an alert under the same
            // title ("you can turn the categories on later in Health").
            let confirm = owner.alerts.buttons["OK"]
            if confirm.exists, confirm.isHittable {
                confirm.tap()
                settle(1.5)
                note("confirmed Health access answer")
                if healthSheetTitle(in: owner) == nil { return }
                continue
            }
            if let decline = hittableButton(in: owner, labels: Self.declineLabels) {
                // Read the label first: once tapped, the button is gone and any
                // query on it fails the case.
                let label = decline.label
                decline.tap()
                settle(2)
                note("answered Health access (\(label))")
                if healthSheetTitle(in: owner) == nil { return }
            }
            owner.swipeUp(velocity: .fast)
        }
        note("Health access sheet stayed up; its tree:\n\(owner.debugDescription)")
    }

    private func healthSheetTitle(in owner: XCUIApplication) -> XCUIElement? {
        for title in Self.sheetTitles {
            let element = owner.staticTexts[title]
            if element.exists { return element }
        }
        return nil
    }

    private func hittableButton(in owner: XCUIApplication, labels: [String]) -> XCUIElement? {
        for label in labels {
            let button = owner.buttons[label]
            if button.exists, button.isHittable { return button }
        }
        return nil
    }
}
