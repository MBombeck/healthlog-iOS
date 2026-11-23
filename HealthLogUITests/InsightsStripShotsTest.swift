import XCTest

/// **Pictures of the Insights head and strip over the pager, for the eye.**
///
/// On request only: writes PNGs into the folder `HL_SHOT_DIR` names (set as
/// `TEST_RUNNER_HL_SHOT_DIR`). Without it the walk still runs and checks that
/// the pages open under the one strip. For the picture in the middle of a
/// swipe it writes `mid.ready` and holds the finger on the screen for a few
/// seconds; a host script takes that picture with `simctl io screenshot`.
@MainActor
final class InsightsStripShotsTest: XCTestCase {
    private var app = XCUIApplication()

    private nonisolated var shotDirectory: String {
        ProcessInfo.processInfo.environment["HL_SHOT_DIR"] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_stripPictures() {
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
        let tab = app.tabBars.buttons.containing(.image, identifier: "sparkles").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Insights tab")
        tab.tap()
        XCTAssertTrue(
            element("insights.page.header.title.overview").waitForExistence(timeout: 30),
            "the Insights overview did not open"
        )
        // One strip for the whole tab, not one per page.
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "insights.tabStrip").count, 1,
            "the Insights tab draws more or less than one strip"
        )
        settle(4)
        shot("p3-overview")

        open("healthlog://insights/blood-pressure", page: "insights.page.bloodPressure")
        shot("p3-blood-pressure")
        // The head stands above the strip, the strip above the content.
        let title = element("insights.page.header.title.bloodPressure")
        let strip = element("insights.tabStrip")
        XCTAssertTrue(title.exists && strip.exists, "no head or no strip on the blood pressure page")
        XCTAssertLessThanOrEqual(title.frame.maxY, strip.frame.minY + 1, "the title does not stand above the strip")
        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3))
        low.press(forDuration: 0.01, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0)
        settle(2)
        shot("p3-blood-pressure-scrolled")

        open("healthlog://insights/sleep", page: "insights.page.sleep")
        shot("p3-sleep")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "insights.tabStrip").count, 1,
            "after paging the tab still draws one strip"
        )

        // Half a swipe, held: the next page comes in under the same strip.
        signal("mid.ready")
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.23))
        let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.23))
        right.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 4)
        settle(2)
        XCTAssertTrue(element("insights.pager").exists, "the pager left the screen")
    }

    // MARK: - Helpers

    private func open(_ link: String, page: String) {
        if let url = URL(string: link) {
            XCUIDevice.shared.system.open(url)
        }
        XCTAssertTrue(element(page).waitForExistence(timeout: 30), "\(page) did not open")
        settle(4)
    }

    private func shot(_ name: String) {
        let directory = shotDirectory
        guard !directory.isEmpty else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? data.write(to: url)
    }

    private func signal(_ name: String) {
        let directory = shotDirectory
        guard !directory.isEmpty else { return }
        FileManager.default.createFile(
            atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path,
            contents: Data()
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
