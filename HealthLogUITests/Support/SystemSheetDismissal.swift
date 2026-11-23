import XCTest

/// **The handling contract for a sheet the app does not own.**
///
/// `09-16-final`'s only non-audit failure was
/// `AuthJourneyUITest/testPasswordLoginWithHealthKitDeniedReachesShell`:
/// "Onboarding step did not advance after tapping its skip affordance". Its own
/// attachment answered why — the app's step was intact, both affordances were
/// present, and iOS's own
///
///     Sheet, {{41.0, 315.0}, {320.0, 272.0}}, label: 'Passwort sichern?'
///
/// was standing over them, presented by a DIFFERENT pid, swallowing the tap.
/// The release pipeline runs that class as the release UI gate and
/// has no resume path, so the sheet can burn a build number.
///
/// **This is not a determinism fix and is not presented as one.** The app cannot
/// suppress an OS-owned password prompt, and the sheet has never reproduced on
/// demand (11-03, 12-12 and 14-05 each looked for it and did not find it). What
/// is deliverable is a CONTRACT, and this file is it:
///
/// 1. **Detected** by the measured shape rather than by hope — exactly two
///    buttons, no text fields, no secure fields. Anything else is refused, so an
///    app-owned error surface can never be dismissed by this code and then
///    silently pass.
/// 2. **Dismissed** through the declining button, bounded at two attempts.
/// 3. **Logged by name** — `ui-gate-dismissed-system-sheet label=…`. This is the
///    part the ledger was missing: without it a gate log cannot distinguish
///    "the sheet never appeared" from "the sheet appeared and was handled", and
///    those are very different facts about a release run.
/// 4. **Retried once** by the caller, which re-tests hittability afterwards.
///
/// **Prevention was NOT attempted, deliberately.** The obvious lever is a
/// simulator-side AutoFill/password-save default, and this operation's standing
/// constraint is that an executor does not mutate a simulator device. A gate
/// that quietly reconfigures the machine it measures is a worse trade than a
/// gate that handles the interruption in the open. Recorded here rather than
/// left as an unexplained omission.
///
/// **Where it lives, and why here.** `AuthJourneyUITest.swift` sits at exactly
/// **600 lines**, SwiftLint's `file_length` ceiling; anything added there has to
/// move something out first. This file IS that move: the helper was private to
/// one journey, so `Phase8OnboardingUITests`, `WebLoginJourneyUITest` and every
/// other journey that walks the same onboarding steps had no access to it.
enum SystemSheetDismissal {
    /// The named line a gate log carries when the sheet was met and handled.
    /// Deliberately one closed-vocabulary line with the sheet's label and
    /// nothing else — no field values, no credentials, nothing the sheet
    /// contains.
    static let logPrefix = "ui-gate-dismissed-system-sheet"

    /// **The measured shape of iOS's password-save prompt.**
    ///
    /// Both recorded reproductions (09-16's attachment and 15/16's) show the
    /// same geometry: a `Sheet` carrying exactly two buttons and no input
    /// fields. The app's own sheets in this flow either carry inputs or carry a
    /// different button count, so the predicate is a gate, not a guess — and it
    /// is written as a pure function of the counts so a future reader can check
    /// it against a new attachment without running anything.
    static func looksLikeSystemPasswordPrompt(
        buttonCount: Int,
        hasTextFields: Bool,
        hasSecureTextFields: Bool
    ) -> Bool {
        buttonCount == 2 && !hasTextFields && !hasSecureTextFields
    }

    /// Detects, dismisses, logs and reports. Returns `true` when a sheet was
    /// dismissed — the caller re-checks hittability and retries its tap.
    ///
    /// Refuses (with a test failure) rather than guessing whenever the surface
    /// is not the measured shape: an alert in the way, an input-bearing sheet,
    /// a sheet whose decline button is not hittable, or a sheet that survives
    /// two bounded attempts. Each of those is a real finding and none of them
    /// may be swallowed by a helper whose job is to keep a gate honest.
    @MainActor
    @discardableResult
    static func dismissIfPresent(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        // The pad presents the same prompt as a centered alert, not a sheet.
        if dismissPasswordAlertIfPresent(in: app) { return true }
        let sheet = app.sheets.firstMatch
        guard sheet.exists else { return false }

        for attempt in 1 ... 2 {
            guard !app.alerts.firstMatch.exists else {
                XCTFail(
                    "Unexpected alert appeared while waiting for an onboarding control",
                    file: file,
                    line: line
                )
                return false
            }
            guard looksLikeSystemPasswordPrompt(
                buttonCount: sheet.buttons.count,
                hasTextFields: sheet.textFields.firstMatch.exists,
                hasSecureTextFields: sheet.secureTextFields.firstMatch.exists
            ) else {
                XCTFail(
                    "Refusing to dismiss an unexpected app-owned sheet during onboarding",
                    file: file,
                    line: line
                )
                return false
            }

            let declineSave = sheet.buttons.element(boundBy: 0)
            guard declineSave.isHittable else {
                XCTFail(
                    "System sheet appeared but its dismiss button is not hittable",
                    file: file,
                    line: line
                )
                return false
            }
            let label = sheet.label
            declineSave.tap()
            if sheet.waitForNonExistence(timeout: 3) {
                // The line the ledger was missing. A run that meets the sheet
                // now SAYS so, so "it did not appear" and "it appeared and was
                // handled" stop looking identical in a gate log.
                print("\(logPrefix) label=\(label.isEmpty ? "<unlabelled>" : label) attempt=\(attempt)")
                return true
            }

            if attempt == 2 {
                XCTFail(
                    "System sheet remained after two bounded dismissal attempts",
                    file: file,
                    line: line
                )
                return false
            }
        }

        return false
    }

    /// The password-save prompt as the pad shows it: an `Alert` titled
    /// "Save Password?" (any app language) with two buttons, the first of which
    /// declines. Any other alert is left alone, so an unexpected one still
    /// surfaces as the caller's failure.
    @MainActor
    private static func dismissPasswordAlertIfPresent(in app: XCUIApplication) -> Bool {
        let alert = app.alerts.matching(NSPredicate(
            format: "label CONTAINS[c] 'password' OR label CONTAINS[c] 'passwort' OR label CONTAINS[c] 'wachtwoord'"
        )).firstMatch
        guard alert.exists, alert.buttons.count == 2, !alert.textFields.firstMatch.exists else { return false }
        let decline = alert.buttons.element(boundBy: 0)
        guard decline.isHittable else { return false }
        let label = alert.label
        decline.tap()
        guard alert.waitForNonExistence(timeout: 3) else { return false }
        print("\(logPrefix) label=\(label) attempt=1")
        return true
    }

    /// Waits for the step a tap was meant to reveal, and
    /// recovers the one way that tap can be lost without the app being wrong.
    ///
    /// INT-Q's red iteration (`AuthJourneyUITest.swift:94`) is the case the
    /// pre-tap contract above cannot close: two sheet-free hittable samples at
    /// 11.28 s and 11.54 s, the tap at 11.64 s, and iOS's "Passwort sichern?"
    /// presented in between. The tap landed on the sheet, the step never moved,
    /// and the 25 s wait for its successor only ever asked for the successor, so
    /// the sheet stood there unhandled until the deadline. The sheet's timing is
    /// the OS's, so no amount of sampling BEFORE the tap makes that window
    /// zero; it has to be handled AFTER the tap as well.
    ///
    /// So while the successor is absent this keeps checking for the sheet, and
    /// only when it dismissed one (same shape gate, same refusals, same log
    /// line) does it call `retap`. The claim stays the caller's: the successor
    /// must still appear within `timeout`, and nothing but an OS-owned sheet of
    /// the measured shape earns a second tap.
    @MainActor
    static func awaitSuccessor(
        timeout: TimeInterval,
        in app: XCUIApplication,
        retap: () -> Void,
        until arrived: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if arrived() { return true }
            if dismissIfPresent(in: app) {
                if !arrived() { retap() }
                continue
            }
            usleep(250_000)
        }
        return arrived()
    }
}
