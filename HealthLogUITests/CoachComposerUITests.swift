import XCTest

/// The Coach composer: one row in one container, the field in front and
/// the mic and the send button behind it, both on the centre of the text
/// line. Send is there only with text and then takes the edge; the mic
/// answers every tap, and a failed start leaves a hint line inside the
/// container and the mic behind. The "AI-generated, not medical advice"
/// line greets a new conversation and leaves with its first message.
///
/// World: the hermetic shell with `-uitest-coach-r` and `-uitest-citations`
/// (the server-arm Coach) and, for the mic, `-uitest-coach-dictation`
/// (dictation counts as possible, the start fails). With `HL_SWEEP_OUT` set
/// the cases also write pictures there; `HL_SWEEP_APPEARANCE=light` and
/// `HL_SWEEP_XXL=1` (largest text) change the launch for them.
@MainActor
final class CoachComposerUITests: XCTestCase {
    private var app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_sendAppearsWithTextAndTheMicMovesAside() throws {
        try openCoach(extra: ["-uitest-coach-dictation"])
        let mic = app.buttons["coach.composer.mic"]
        let send = app.buttons["coach.composer.send"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "The mic must be offered")
        XCTAssertFalse(send.exists, "Without text there is no send button")
        let micAloneMaxX = mic.frame.maxX
        shot("composer-empty")

        let field = composerField()
        field.tap()
        // A short first word stays on one line at every text size.
        let first = "Schlaf"
        field.typeText(first)
        XCTAssertTrue(send.waitForExistence(timeout: 5), "With text the send button must be there")
        XCTAssertTrue(send.isEnabled, "Send must be active with text")
        // Send takes the place at the edge, the mic moves one place in.
        XCTAssertEqual(send.frame.maxX, micAloneMaxX, accuracy: 0.5, "Send stands where the mic stood")
        XCTAssertEqual(send.frame.minX, mic.frame.maxX, accuracy: 0.5, "Mic and send stand side by side")
        // One line: both circles stand on the centre of the text line.
        XCTAssertEqual(mic.frame.midY, field.frame.midY, accuracy: 1, "The mic stands on the line's centre")
        XCTAssertEqual(send.frame.midY, field.frame.midY, accuracy: 1, "Send stands on the line's centre")
        XCTAssertGreaterThan(mic.frame.minX, field.frame.maxX - 0.5, "The buttons stand behind the field")
        logFrames(mic: mic, send: send)

        // More lines: the circles stay down at the last one.
        let rest = ", wie war die Woche und wie habe ich geschlafen?"
        field.typeText(rest)
        let question = first + rest
        if field.frame.height > mic.frame.height + 1 {
            // The circle's centre sits in the last line, so in the lowest
            // third of a field with two or more lines.
            XCTAssertGreaterThanOrEqual(
                mic.frame.midY, field.frame.maxY - field.frame.height / 3,
                "With more lines the mic stays at the last one"
            )
            XCTAssertEqual(mic.frame.midY, send.frame.midY, accuracy: 0.5, "Mic and send stay on one line")
        }
        shot("composer-text")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: question.count))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: send)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(mic.frame.maxX, micAloneMaxX, accuracy: 0.5, "Without text the mic is back at the edge")
    }

    func test_micTapShowsHintInsideTheComposerAndMicStays() throws {
        try openCoach(extra: ["-uitest-coach-dictation"])
        let mic = app.buttons["coach.composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "The mic must be offered")
        let field = composerField()
        field.tap()
        field.typeText("Wie habe ich geschlafen?")
        mic.tap()
        // The starting disc stands while the fake start waits; the pause lets
        // the pressed highlight fade first.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "press highlight")], timeout: 0.7)
        shot("composer-mic-starting")
        let hint = app.descendants(matching: .any)["coach.dictation.hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "A failed start must leave a hint line")
        XCTAssertTrue(mic.exists && mic.isHittable, "The mic must stay after a failed start")
        // Its own line inside the container, above the field and the
        // buttons, on the field's leading edge.
        let composer = app.descendants(matching: .any)["coach.composer"]
        XCTAssertTrue(composer.exists, "The composer container must be found")
        XCTAssertTrue(composer.frame.insetBy(dx: -0.5, dy: -0.5).contains(hint.frame), "The hint stands inside the composer")
        XCTAssertLessThanOrEqual(hint.frame.maxY, field.frame.minY + 0.5, "The hint stands above the field")
        XCTAssertLessThanOrEqual(hint.frame.maxY, mic.frame.minY + 0.5, "The hint stands above the buttons")
        XCTAssertEqual(hint.frame.minX, field.frame.minX, accuracy: 1, "The hint shares the field's inset")
        XCTAssertEqual(field.value as? String, "Wie habe ich geschlafen?", "The draft stays as it was")
        logFrames(mic: mic, send: app.buttons["coach.composer.send"])
        shot("composer-mic-hint")
    }

    func test_noteOnlyInANewConversation() throws {
        try openCoach(extra: [])
        let options = app.buttons["Coach-Optionen"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "The coach options are missing")
        options.tap()
        let fresh = app.buttons["Neue Unterhaltung"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 5), "New conversation is missing")
        fresh.tap()

        let field = composerField()
        let note = app.descendants(matching: .any)["coach.aiGeneratedNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "A new conversation shows the note")
        XCTAssertLessThanOrEqual(note.frame.maxY, field.frame.minY, "No note under the field")
        shot("fresh-conversation")

        field.tap()
        field.typeText("Wie habe ich diese Woche geschlafen?")
        let send = app.buttons["coach.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send must be there with text")
        send.tap()
        // The first message ends the empty state, and the note goes with it.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: note)
        waitForExpectations(timeout: 15)
        shot("conversation-without-note")
    }

    // MARK: - Helpers

    private func openCoach(extra: [String]) throws {
        app = XCUIApplication()
        var arguments = [
            "-uitest-marketing", "-uitest-sweep", "-uitest-coach-r", "-uitest-citations",
            "-hl.healthkit.requestedAt.hermetic-user", "true",
            "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
        ] + extra
        if env["HL_SWEEP_APPEARANCE"] == "light" {
            arguments += HermeticAppearance.lightArguments
        }
        if env["HL_SWEEP_XXL"] == "1" {
            arguments += [
                "-UIPreferredContentSizeCategoryName",
                env["HL_SWEEP_XXL_SIZE"] ?? "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchHermeticAndWaitForDashboard(extraArguments: arguments, timeout: 120)
        acceptConsent()
        try XCUIDevice.shared.system.open(XCTUnwrap(URL(string: "healthlog://coach")))
        for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
            let coin = app.buttons[id]
            if coin.waitForExistence(timeout: 8), coin.isHittable {
                coin.tap()
                break
            }
        }
        acceptConsent()
        XCTAssertTrue(composerField().waitForExistence(timeout: 15), "Coach composer missing")
    }

    private func composerField() -> XCUIElement {
        app.descendants(matching: .any)["coach.composer.field"].firstMatch
    }

    private func acceptConsent() {
        for label in ["Akzeptieren", "Accept"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                return
            }
        }
    }

    /// Mic and send share one frame; the run log keeps both for the report.
    private func logFrames(mic: XCUIElement, send: XCUIElement) {
        XCTAssertEqual(mic.frame.size, send.frame.size, "Mic and send share one frame")
        XCTAssertEqual(mic.frame.midY, send.frame.midY, accuracy: 0.5, "Mic and send stand on one line")
        let line = "composer frames mic=\(mic.frame) send=\(send.frame)"
        print(line)
        add(XCTAttachment(string: line))
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let out = env["HL_SWEEP_OUT"], !out.isEmpty else { return }
        let url = URL(fileURLWithPath: out).appendingPathComponent("k2-\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
