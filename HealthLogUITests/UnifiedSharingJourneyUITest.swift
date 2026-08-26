import XCTest

/// **Phase 18 / 18-03 — the one sharing journey, walked hermetically.**
///
/// Mehr → the header share glyph → the unified surface → select-all → a period
/// → a labelled link. Every byte comes from the bundled hermetic fixtures
/// (`-uitest-hermetic`), including the leaf vocabulary and the minted link, so
/// the walk is network-free and deterministic.
///
/// **Two assertions carry decisions rather than layout.** Before anything is
/// chosen, the surface states that nothing is included and a link would carry
/// documents only — that is E1.2's honesty half, and it must be visible at the
/// moment it is true. After "Alles auswählen" that statement is gone, because
/// selecting everything is an act with a consequence the user can see.
@MainActor
final class UnifiedSharingJourneyUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_share_journey_selects_everything_and_creates_a_link() {
        let app = XCUIApplication()
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)

        // Mehr tab → the header share glyph. Since 18-03 that glyph opens the
        // one sharing surface directly; there is no hub in between.
        let moreTab = app.tabBars.buttons.element(boundBy: max(0, app.tabBars.buttons.count - 1))
        XCTAssertTrue(moreTab.waitForExistence(timeout: 15), "More tab missing")
        moreTab.tap()

        let shareGlyph = app.buttons["more.toolbar.share"]
        XCTAssertTrue(shareGlyph.waitForExistence(timeout: 15), "Header share glyph missing")
        shareGlyph.tap()

        // Question 1 — what. The summary proves the server's vocabulary landed.
        let summary = app.descendants(matching: .any)
            .matching(identifier: "sharing.unified.summary").firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 20),
            "The selection summary never appeared — did the capabilities fixture serve share.leaves?"
        )

        // E1.2 — the empty default says what it means, before anything is shared.
        let emptyMeaning = app.descendants(matching: .any)
            .matching(identifier: "sharing.unified.emptyMeaning").firstMatch
        XCTAssertTrue(
            emptyMeaning.waitForExistence(timeout: 10),
            "The documents-only statement is missing on an untouched selection (E1.2)"
        )

        // The explicit act.
        let selectAll = app.buttons["sharing.unified.selectAll"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Select-everything control missing")
        selectAll.tap()

        XCTAssertFalse(
            emptyMeaning.exists,
            "The documents-only statement survived select-all — it is state-dependent by design"
        )

        pickTheLongestPeriod(in: app)
        labelAndCreate(in: app)
        assertTheLinkRevealsItselfInPlace(in: app)
    }

    // MARK: - Steps

    /// Question 2 — the period. Its segments are the unified intersection.
    private func pickTheLongestPeriod(in app: XCUIApplication) {
        let period = scrollTo(identifier: "sharing.unified.period", in: app)
        XCTAssertTrue(period.waitForExistence(timeout: 10), "Period picker missing")
        let segments = period.buttons
        if segments.count >= 2 {
            segments.element(boundBy: segments.count - 1).tap()
        }
    }

    /// Question 3 — the form, and the fields it still needs. Link is the
    /// preselected form on this entry, so the label field is already there.
    private func labelAndCreate(in app: XCUIApplication) {
        var scrolls = 0
        let label = app.textFields["sharing.unified.link.label"]
        while !label.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(label.waitForExistence(timeout: 10), "Link label field missing")
        label.tap()
        label.typeText("Dr. Hermetic")

        let produce = scrollTo(identifier: "sharing.unified.produce", in: app, kind: .button)
        XCTAssertTrue(produce.waitForExistence(timeout: 10), "Produce action missing")
        produce.tap()
    }

    /// The one-time reveal renders IN PLACE — this surface has no modal.
    private func assertTheLinkRevealsItselfInPlace(in app: XCUIApplication) {
        let shareRow = app.descendants(matching: .any)
            .matching(identifier: "shareLink.token.share").firstMatch
        XCTAssertTrue(
            shareRow.waitForExistence(timeout: 25),
            "The minted link never revealed itself — the token panel should render in place"
        )
        let passphrase = app.descendants(matching: .any)
            .matching(identifier: "shareLink.passphrase.value").firstMatch
        XCTAssertTrue(
            passphrase.waitForExistence(timeout: 10),
            "The passphrase half of the Class-D reveal is missing"
        )
    }

    private func scrollTo(
        identifier: String,
        in app: XCUIApplication,
        kind: XCUIElement.ElementType = .any
    ) -> XCUIElement {
        let element = kind == .button
            ? app.buttons[identifier]
            : app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        var scrolls = 0
        while !element.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        return element
    }
}
