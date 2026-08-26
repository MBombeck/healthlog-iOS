import XCTest

/// **Phase 08 Wave 0 — the document surface, hermetically.**
///
/// Plan 08-02's store suite proved the *publication* of a superseded document
/// query is fenced. These cases are about the other half: what is on screen
/// while the newest answer is still in flight, what the screen says when a bulk
/// action is half-refused, and what it still offers when the module is off.
/// The fixtures state each of those worlds by name — no picker, no real file,
/// no network.
final class Phase8DocumentsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: RED — a new filter must not keep painting the old answer

    /// `DocumentsScreen.phase` returns `.loaded` whenever the snapshot is
    /// non-empty, without ever consulting `isLoading`. So while the newest
    /// filter is in flight the previous filter's rows stay fully rendered, with
    /// no loading state anywhere — the user reads a list that answers a question
    /// they have already replaced.
    ///
    /// The fixture holds the `beta` answer open for four seconds, and the
    /// assertion is taken well inside that window.
    @MainActor
    func testNewestFilterWins() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.documentsDelayedFilter)
        guard openDocuments(app, readyIdentifier: "documents.toolbar.upload") else { return }

        let alpha = app.staticTexts["Alpha Report"]
        guard app.awaitPhase8(alpha, "the unfiltered document list") else { return }

        guard let search = revealSearchField(app) else { return }
        search.tap()
        search.typeText("beta")

        // Past the 250 ms debounce and well inside the fixture's four-second
        // hold: the newest filter has been submitted and has not answered.
        Thread.sleep(forTimeInterval: 1.5)

        var violations: [String] = []
        if alpha.exists {
            violations.append("the previous filter's document was still on screen under the newest filter")
        }
        if !app.activityIndicators.firstMatch.exists, !app.staticTexts["Beta Report"].exists {
            violations.append("no loading state was offered while the newest filter was still in flight")
        }
        record(violations, for: "newest-filter")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI older document filter replaced the newest result"
        )
    }

    // MARK: RED — an import failure and a half-refused bulk are visible

    /// Two halves of the same promise. A bulk delete the server half-refuses
    /// clears the whole selection and reports nothing, so the refused id cannot
    /// be retried and nobody was told it failed. And the upload sheet's failure
    /// text carries no accessibility identifier at all, so no automated check —
    /// including this one — can establish that a failed import was ever shown.
    @MainActor
    func testVisibleImportAndPartialFailure() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.documentsPartialBulk)
        guard openDocuments(app, readyIdentifier: "documents.toolbar.upload") else { return }
        guard app.awaitPhase8(app.staticTexts["Alpha Report"], "the document list") else { return }

        var violations: [String] = []

        guard selectBothRows(app) else { return }

        // The bulk bar's actions carry accessibility LABELS, not identifiers
        // (`DocumentBulkBar.bulkIcon`), so the delete verb is the landmark — and
        // the simulator this gate runs on is German, which is why it is matched
        // against both catalogue values rather than the English one.
        let trash = Self.localized(app, ["Delete", "Löschen"])
        guard app.awaitPhase8(trash, "the bulk bar's delete action") else { return }
        trash.tap()

        // The server applied one id and refused the other. The refused id must
        // stay selected — which means the bulk bar must still be there.
        Thread.sleep(forTimeInterval: 3)
        if !Self.localized(app, ["Delete", "Löschen"]).exists {
            violations.append("the bulk bar closed although one id was refused, so it cannot be retried")
        }
        let done = Self.localized(app, ["Done", "Fertig"])
        if done.exists { done.tap() }
        let upload = app.phase8Element("documents.toolbar.upload")
        guard app.awaitPhase8(upload, "the upload entry") else { return }
        upload.tap()
        if app.awaitPhase8(Self.localized(app, ["Choose a file", "Datei auswählen"]), "the upload sheet") {
            if !app.phase8Element("documents.upload.error").exists {
                violations.append(
                    "the upload sheet's failure text carries no identifier, so a hidden failure is unfalsifiable"
                )
            }
        }

        record(violations, for: "import-and-partial-bulk")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI document import or partial failure was hidden"
        )
    }

    // MARK: RED — a disabled module offers nothing

    /// `DocumentsScreen` gates its toolbar on the `@State` module flag it read
    /// once on appear, and applies `.searchable` to the whole `Group`
    /// unconditionally. A `403 module.disabled` that lands mid-flight therefore
    /// swaps the content for the enable-CTA while leaving the search field, the
    /// select mode and the upload entry live over it — every one of them
    /// pointing at a module that is off.
    @MainActor
    func testDisabledModuleHasNoControls() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.documentsModuleDisabled)
        guard openDocuments(app, readyIdentifier: "documents.optIn.enable") else { return }

        var violations: [String] = []
        if app.phase8Element("documents.toolbar.upload").exists {
            violations.append("the upload entry stayed live over the enable-CTA")
        }
        if app.phase8Element("documents.toolbar.select").exists {
            violations.append("multi-select stayed live over the enable-CTA")
        }
        if app.searchFields.firstMatch.exists || Self.localized(app, ["Search", "Suchen"]).exists {
            violations.append("the search affordance stayed live over the enable-CTA")
        }
        record(violations, for: "module-disabled")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI disabled Documents exposed unusable controls"
        )
    }

    // MARK: - Navigation

    /// More tab → the Documents row → the screen's scenario-specific landmark.
    @MainActor
    private func openDocuments(_ app: XCUIApplication, readyIdentifier: String) -> Bool {
        app.phase8Tab("ellipsis").tap()
        let row = app.scrollToPhase8("more.row.documents")
        guard row.exists else { return false }
        row.tap()
        return app.awaitPhase8(
            app.phase8Element(readyIdentifier),
            "the Documents screen landmark \(readyIdentifier)"
        )
    }

    /// Enters selection mode and selects both fixture rows.
    ///
    /// The bulk bar only mounts once the selection is non-empty, and the first
    /// gate run never got one: a tap on the row's static text while the toolbar
    /// was still swapping did not reach the row's button. So the mode is
    /// confirmed first, each row is tried as a cell and then as its text, and
    /// the tree is dumped if the bar still never appears — an unselected row is
    /// an infrastructure miss, never a finding.
    @MainActor
    private func selectBothRows(_ app: XCUIApplication) -> Bool {
        let select = app.phase8Element("documents.toolbar.select")
        guard app.awaitPhase8(select, "the multi-select toolbar entry") else { return false }
        select.tap()

        // Selection mode has to be *observed* before the rows are tapped. Out of
        // it the same row is a `NavigationLink`, so a tap that lands one beat
        // early pushes the detail screen instead of selecting — which is exactly
        // what happened on the first gate run. The filter menu is built only
        // when selection mode is off, so its disappearance is the signal.
        let filterMenu = app.phase8Element("documents.toolbar.filter")
        guard filterMenu.waitForNonExistence(timeout: 10) else {
            XCTFail("Documents never entered selection mode")
            return false
        }

        for title in ["Alpha Report", "Beta Report"] {
            let cell = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            let text = app.staticTexts[title]
            if cell.exists, cell.isHittable {
                cell.tap()
            } else if app.awaitPhase8(text, "the \(title) row in selection mode") {
                text.tap()
            } else {
                return false
            }
        }

        if !app.buttons["Delete"].waitForExistence(timeout: 8) {
            print("PHASE8-DIAGNOSTIC buttons: \(app.buttons.allElementsBoundByIndex.prefix(40).map(\.label))")
            print("PHASE8-DIAGNOSTIC cells: \(app.cells.allElementsBoundByIndex.prefix(20).map(\.label))")
        }
        return true
    }

    /// The search field, revealing it first when the runtime collapses
    /// `.searchable` into a toolbar search button (iOS 26). The first gate run
    /// failed here: `app.searchFields` was empty because the field had not been
    /// summoned yet.
    @MainActor
    private func revealSearchField(_ app: XCUIApplication) -> XCUIElement? {
        if app.searchFields.firstMatch.waitForExistence(timeout: 5) {
            return app.searchFields.firstMatch
        }
        for candidate in [
            Self.localized(app, ["Search", "Suchen"]),
            app.buttons.containing(.image, identifier: "magnifyingglass").firstMatch
        ] where candidate.exists {
            candidate.tap()
            if app.searchFields.firstMatch.waitForExistence(timeout: 5) {
                return app.searchFields.firstMatch
            }
        }
        app.swipeDown()
        guard app.awaitPhase8(app.searchFields.firstMatch, "the document search field") else { return nil }
        return app.searchFields.firstMatch
    }

    /// Records what a RED actually found, so the gate log carries the evidence
    /// the single fixed marker cannot.
    private func record(_ violations: [String], for test: String) {
        print("PHASE8-VIOLATIONS \(test): \(violations)")
    }

    /// A button matched against every catalogue value of its key.
    ///
    /// `DocumentBulkBar` gives its actions accessibility *labels*, not
    /// identifiers, and this gate's simulator runs in German — the first two
    /// runs missed "Löschen" while looking for "Delete". Both `Localizable`
    /// values are named, so the landmark is exact in either locale and a third
    /// language would fail loudly rather than silently.
    @MainActor
    private static func localized(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }
}
