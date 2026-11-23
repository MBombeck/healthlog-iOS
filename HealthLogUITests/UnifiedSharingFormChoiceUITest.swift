import XCTest

/// **Sharing opens with no output form, and the first tap on "Link" is enough.**
///
/// The surface used to open with "Link" drawn as chosen while the steps a form
/// choice runs had not run, so on a device the link only worked after tapping
/// "Link" again. This walk opens the surface in the hermetic world, checks that
/// nothing is chosen and nothing can be produced, taps "Link" once and mints.
///
/// With `TEST_RUNNER_HL_SWEEP_OUT` set it also photographs the three states,
/// in the dark and in the light appearance (`HL_SWEEP_LANG` picks the language).
@MainActor
final class UnifiedSharingFormChoiceUITest: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private var outputDir: String {
        env["HL_SWEEP_OUT"] ?? ""
    }

    override func setUpWithError() throws {
        // Every state is checked and photographed even when an earlier check
        // fails, so a red run still shows what the screen did.
        continueAfterFailure = true
    }

    func test_share_opens_without_a_form_and_links_on_first_tap() {
        walk(light: false)
        if !outputDir.isEmpty {
            walk(light: true)
        }
    }

    // MARK: - The walk

    private func walk(light: Bool) {
        let app = XCUIApplication()
        let language = UITestLanguage(environmentValue: env["HL_SWEEP_LANG"])
        _ = app.launchHermeticAndWaitForDashboard(
            extraArguments: language.launchArguments + (light ? HermeticAppearance.lightArguments : []),
            timeout: 90
        )
        let suffix = light ? "hell" : "dunkel"
        openSharing(in: app)

        let linkRow = scrollTo(app.buttons["sharing.unified.form.link"], in: app)
        XCTAssertTrue(linkRow.waitForExistence(timeout: 20), "The form rows never appeared")
        for form in ["link", "pdf", "zip", "fhir"] {
            XCTAssertFalse(
                app.buttons["sharing.unified.form.\(form)"].isSelected,
                "\(form) is drawn as chosen before the user chose anything"
            )
        }
        let label = app.textFields["sharing.unified.link.label"]
        XCTAssertFalse(label.exists, "The link's label card shows before a form was chosen")
        shot("ts-1-offen-\(suffix)")
        let produce = scrollTo(app.buttons["sharing.unified.produce"], in: app)
        XCTAssertTrue(produce.waitForExistence(timeout: 10), "Produce action missing")
        XCTAssertFalse(produce.isEnabled, "The action is live before a form was chosen")
        shot("ts-1b-aktion-\(suffix)")

        let link = scrollTo(app.buttons["sharing.unified.form.link"], in: app, up: true)
        link.tap()
        XCTAssertTrue(link.isSelected, "Link is not drawn as chosen after one tap")
        let labelField = scrollTo(label, in: app)
        XCTAssertTrue(labelField.waitForExistence(timeout: 10), "The label card did not appear after choosing Link")
        shot("ts-2-link-\(suffix)")

        labelField.tap()
        labelField.typeText("Dr. Hermetic")
        let action = scrollTo(app.buttons["sharing.unified.produce"], in: app)
        XCTAssertTrue(action.isEnabled, "The link action stayed dead after one tap on Link")
        action.tap()

        let tokenRow = app.descendants(matching: .any).matching(identifier: "shareLink.token.share").firstMatch
        XCTAssertTrue(tokenRow.waitForExistence(timeout: 25), "The first tap on the action minted no link")
        shot("ts-3-erzeugt-\(suffix)")
        app.terminate()
    }

    private func openSharing(in app: XCUIApplication) {
        XCTAssertTrue(ShellNavigator.select(tab: .more, in: app, timeout: 15), "More tab missing")
        let shareGlyph = app.buttons["more.toolbar.share"]
        XCTAssertTrue(shareGlyph.waitForExistence(timeout: 15), "Header share glyph missing")
        shareGlyph.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "sharing.unified.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "The sharing surface never loaded its selection")
    }

    // MARK: - Helpers

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) -> XCUIElement {
        var scrolls = 0
        while !(element.exists && element.isHittable), scrolls < 8 {
            if up { app.swipeDown() } else { app.swipeUp() }
            scrolls += 1
        }
        return element
    }

    private func shot(_ name: String) {
        guard !outputDir.isEmpty else { return }
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir),
            withIntermediateDirectories: true
        )
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
