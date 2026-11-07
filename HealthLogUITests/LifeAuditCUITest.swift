import XCTest

/// **AUDITC (1.5.0, #132)** — AUDIT-C in the alcohol section: answered in
/// the card, the server's result shown, an entry removed after a question in
/// place. The fixture server (`-uitest-life`) holds one entry from 2025, so
/// the questionnaire is due again, and scores like the server (a woman's
/// profile).
final class LifeAuditCUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnswerShowsTheServerResultAndAnEntryCanBeRemoved() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchHermeticAndWaitForDashboard(extraArguments: ["-uitest-life"], timeout: 120)
        openAlcohol(app)

        let result = app.scrollToPhase8("life.auditC.result")
        XCTAssertTrue(result.label.contains("2 of 12 points"), "Seeded result missing: \(result.label)")
        XCTAssertTrue(result.label.contains("Below the screening cut-off of 3."), result.label)

        app.scrollToPhase8("life.auditC.start").tap()
        XCTAssertTrue(app.phase8Element("life.auditC.item.0").waitForExistence(timeout: 5), "Form did not unfold")
        XCTAssertTrue(
            app.staticTexts["1. How often do you have a drink containing alcohol?"].exists,
            "The stem must be the server's wording, numbered"
        )
        XCTAssertFalse(app.phase8Element("life.auditC.notValidated").exists, "English is validated")
        for (item, points) in [(0, 2), (1, 1), (2, 1)] {
            app.scrollToPhase8("life.auditC.item.\(item).option.\(points)").tap()
        }
        let submit = app.scrollToPhase8("life.auditC.submit")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let saved = NSPredicate(format: "label CONTAINS %@", "4 of 12 points")
        expectation(for: saved, evaluatedWith: app.phase8Element("life.auditC.result"))
        waitForExpectations(timeout: 15)
        let fresh = app.phase8Element("life.auditC.result")
        XCTAssertTrue(fresh.label.contains("At or above the screening cut-off of 3."), fresh.label)
        XCTAssertTrue(fresh.label.contains("Source: Bradley KA et al."), fresh.label)
        XCTAssertFalse(app.phase8Element("life.auditC.submit").exists, "The form folds away after saving")

        let remove = app.scrollToPhase8("life.auditC.history.remove.audit-c-seed")
        remove.tap()
        let confirm = app.scrollToPhase8("life.auditC.history.confirm.audit-c-seed")
        XCTAssertTrue(app.staticTexts["Remove this entry?"].exists, "The question is asked in place")
        confirm.tap()
        XCTAssertTrue(
            app.phase8Element("life.auditC.history.audit-c-seed").waitForNonExistence(timeout: 10),
            "The removed entry is still listed"
        )
    }

    /// POLISH-C (C7) — the one-word answer from before AUDIT-C stands in the
    /// alcohol section, as on the web, and can be removed after a question
    /// asked in place.
    @MainActor
    func testEarlierAnswerIsShownAndCanBeRemoved() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchHermeticAndWaitForDashboard(extraArguments: ["-uitest-life"], timeout: 120)
        openAlcohol(app)

        let legacy = app.scrollToPhase8("life.auditC.legacy")
        XCTAssertTrue(legacy.exists, "The earlier answer is not shown")
        XCTAssertTrue(legacy.label.contains("Earlier answer: Weekly"), legacy.label)
        app.scrollToPhase8("life.auditC.legacy.remove").tap()
        let confirm = app.scrollToPhase8("life.auditC.legacy.confirm")
        XCTAssertTrue(app.staticTexts["Remove the earlier answer?"].exists, "The question is asked in place")
        confirm.tap()
        XCTAssertTrue(
            app.phase8Element("life.auditC.legacy").waitForNonExistence(timeout: 10),
            "The removed answer is still shown"
        )
        XCTAssertTrue(app.phase8Element("life.auditC.intro").exists, "The section stays open")
    }

    /// Screens for the report: de/en, light/dark, the accessibility size, and
    /// Dutch (English original with the note). Only with `HL_SWEEP_OUT`.
    @MainActor
    func testAuditCShots() throws {
        let out = ProcessInfo.processInfo.environment["HL_SWEEP_OUT"] ?? ""
        try XCTSkipIf(out.isEmpty, "HL_SWEEP_OUT not set — shots only on request")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
        continueAfterFailure = true
        let variants = ["de light", "de dark", "en light", "en dark", "nl light", "de light xxl"]
        for variant in variants {
            let parts = variant.split(separator: " ").map(String.init)
            let (language, appearance, xxl) = (parts[0], parts[1], parts.count > 2)
            let locale = ["de": "de_DE", "en": "en_US", "nl": "nl_NL"][language] ?? "en_US"
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(language))",
                "-AppleLocale", locale,
                "-hl.settings.appearance", appearance,
                "-hl.settings.darkDefault.reasserted.v1", "YES"
            ] + (xxl ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            app.launchHermeticAndWaitForDashboard(extraArguments: ["-uitest-life"], timeout: 120)
            let name = "\(language)-\(appearance)\(xxl ? "-xxl" : "")"
            openAlcohol(app)
            shot(app, "\(out)/auditc-section-\(name).png")
            app.scrollToPhase8("life.auditC.start", swipes: 14).tap()
            app.scrollToPhase8("life.auditC.item.0", swipes: 4)
            shot(app, "\(out)/auditc-form-top-\(name).png")
            for (item, points) in [(0, 2), (1, 1), (2, 1)] {
                app.scrollToPhase8("life.auditC.item.\(item).option.\(points)", swipes: 14).tap()
            }
            app.scrollToPhase8("life.auditC.submit", swipes: 14)
            shot(app, "\(out)/auditc-form-bottom-\(name).png")
            app.phase8Element("life.auditC.submit").tap()
            _ = app.phase8Element("life.auditC.submit").waitForNonExistence(timeout: 10)
            // The form folded away above the fold: scroll back up to the result.
            let result = app.phase8Element("life.auditC.result")
            for _ in 0 ..< 10 where !(result.exists && result.isHittable) {
                app.swipeDown()
            }
            shot(app, "\(out)/auditc-result-\(name).png")
            app.scrollToPhase8("life.auditC.history.remove.audit-c-seed", swipes: 14).tap()
            app.scrollToPhase8("life.auditC.history.confirm.audit-c-seed", swipes: 6)
            shot(app, "\(out)/auditc-remove-\(name).png")
            app.terminate()
        }
    }

    // MARK: - Steps

    @MainActor
    private func openAlcohol(_ app: XCUIApplication) {
        let more = app.phase8Tab("ellipsis")
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More tab missing")
        more.tap()
        let aboutMe = app.phase8Element("more.row.about_me")
        XCTAssertTrue(aboutMe.waitForExistence(timeout: 10), "About me row missing")
        aboutMe.tap()
        app.scrollToPhase8("aboutMe.row.lifeCircumstances").tap()
        let header = app.phase8Element("life.section.alcohol.header")
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Life circumstances did not load")
        header.tap()
        XCTAssertTrue(app.phase8Element("life.auditC.intro").waitForExistence(timeout: 5), "Alcohol section did not open")
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ path: String) {
        Thread.sleep(forTimeInterval: 0.8)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
    }
}
