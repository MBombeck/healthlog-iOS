import XCTest

/// **Plan 08-09 — the cancel leg of `testLogoutConfirmationPreservesSessionOnCancel`.**
///
/// Kept in a sibling file for the reason 08-15 put its support-gate legs in
/// one: the primary class stays inside `type_body_length`, and a leg that has
/// to walk a dialog is easier to read next to its own notes than inside a case.
///
/// The case's original two clauses are untouched. They ask whether anything is
/// raised at all and whether the session survives long enough to answer; this
/// asks the question that only becomes askable once something *is* raised — is
/// the non-destructive answer actually non-destructive.
extension Phase8AccessibilityUITests {
    /// Answers the confirmation with Cancel and reports what that cost.
    ///
    /// Returns immediately when no confirmation appeared: the caller has
    /// already recorded that, and a second violation about the same absence
    /// would double-count one defect.
    @MainActor
    func logoutCancelViolations(_ app: XCUIApplication, confirmationExists: Bool) -> [String] {
        guard confirmationExists else { return [] }

        var violations: [String] = []
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch
        let spoken = ([dialog.label] + dialog.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " | ")
        print("PHASE8-DIAGNOSTIC logout dialog: \(spoken)")
        // One inventory, once, on a dialog with three elements — not the
        // per-swipe hierarchy dump 08-15 measured at five minutes. It is what
        // told this leg where the cancel action actually lives.
        print("PHASE8-DIAGNOSTIC logout dialog buttons: \(Self.inventory(dialog.buttons))")
        print("PHASE8-DIAGNOSTIC logout app buttons: \(Self.inventory(app.buttons))")

        // The consequence has to be on screen before the destructive answer is
        // offered. The gate simulator runs in German, so both catalogue values
        // of the one shared sentence are named.
        if !["sign in again", "erneut"].contains(where: { spoken.localizedCaseInsensitiveContains($0) }) {
            violations.append("the confirmation never states what signing out costs")
        }

        if Self.dialogButton(dialog, labels: ["Sign out", "Abmelden"]) == nil {
            violations.append("the confirmation offers no destructive answer")
        }
        // **The non-destructive answer is not always a button, and this run
        // proved it.** On iOS 26 SwiftUI presents `confirmationDialog` as a
        // `Popover` anchored to the row that raised it, and the platform
        // *suppresses* the `.cancel`-role action: the printed hierarchy carries
        // the German title, the consequence and exactly one `Button`
        // (`logout.confirm.signOut`), with the way out rendered as the
        // popover's `PopoverDismissRegion` ("Einblendmenü schließen"). The
        // source keeps its explicit cancel `Button` — it is the correct API and
        // it renders as a button wherever the dialog is presented as a sheet —
        // so this looks for the button first, by both catalogue values and by
        // its identifier, and accepts the dismiss region as what it is: the
        // affordance the OS substituted for it.
        let cancelCandidate = Self.dialogButton(dialog, or: app, labels: ["Cancel", "Abbrechen"])
            ?? [
                app.descendants(matching: .any)["logout.confirm.cancel"],
                app.descendants(matching: .any)["PopoverDismissRegion"]
            ].first { $0.exists }
        guard let cancel = cancelCandidate else {
            print("PHASE8-DIAGNOSTIC logout hierarchy: \(app.debugDescription)")
            violations.append("the confirmation offers no way to take the question back")
            return violations
        }

        cancel.tap()
        if !dialog.waitForNonExistence(timeout: 5) {
            violations.append("the confirmation stayed on screen after the non-destructive answer")
        }
        if app.phase8Element("onboarding.passwordLoginCTA").waitForExistence(timeout: 5) {
            violations.append("cancelling the confirmation ended the session anyway")
        }
        if !app.phase8Element("more.row.sign_out").waitForExistence(timeout: 5) {
            violations.append("cancelling the confirmation did not leave the account screen standing")
        }
        return violations
    }

    /// Every button's identifier and label under one query, for the gate log.
    @MainActor
    static func inventory(_ query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
    }

    /// A button inside the dialog, by either catalogue value.
    ///
    /// The dialog scope is the strict one and is used alone for the destructive
    /// answer, because "Abmelden" is also the label of the row that opened the
    /// dialog and an app-wide query would find that row and call it an answer.
    /// `fallback` widens the search to the whole app for the cancel action,
    /// which UIKit composes outside the sheet element.
    @MainActor
    static func dialogButton(
        _ dialog: XCUIElement,
        or fallback: XCUIApplication? = nil,
        labels: [String]
    ) -> XCUIElement? {
        // **`.firstMatch` is disambiguation, not a relaxed match**, and it is
        // load-bearing since R13-A1 turned the confirmation into an `alert`:
        // SwiftUI publishes each alert action as a `Button` nested inside a
        // `Button` carrying the *same* identifier, so a bare query resolves two
        // elements and `tap()` raises "Multiple matching elements found" before
        // any assertion runs. `AuthJourneyUITest.answerLogoutConfirmation` had
        // already measured exactly this for the destructive answer; the cancel
        // leg now meets it too. Both matches are the same control at the same
        // frame.
        if let inDialog = labels.map({ dialog.buttons[$0] }).first(where: { $0.exists }) { return inDialog.firstMatch }
        guard let fallback else { return nil }
        return labels.map { fallback.buttons[$0] }.first { $0.exists }?.firstMatch
    }
}
