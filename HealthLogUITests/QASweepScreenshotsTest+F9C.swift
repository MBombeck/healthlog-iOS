import XCTest

/// F9-C: the account page as two row cards, and the drawn check of a taken
/// dose and a logged mood, each before and after the confirmation. Only runs
/// when `HL_SWEEP_OUT` is set, like every sweep test.
extension QASweepScreenshotsTest {
    func test_40_f9cAccountAndChecks() {
        boot()
        // The account page itself (the Konto sweep photographs its sheets).
        if openMore(), tap(app.buttons["more.toolbar.gear"], "settings gear") {
            settle(2)
            if let account = probe("settings.hub.account") {
                account.tap()
                settle(3)
                shotToEnd("40-account")
            }
        }

        // The dose: the card before and after "Taken".
        tab("pills.fill")
        scrollUpToTop()
        shot("40-dose-before")
        if tap(element("med.card.action.taken"), "taken") {
            settle(2)
            scrollUpToTop()
            shot("40-dose-after")
        }

        // The mood: the faces before and after a logged face.
        if tapLogTab(), tap(element("capture.picker.row.mood"), "capture row mood") {
            settle(2.5)
            shot("40-mood-before")
            if tap(element("mood.face.4"), "mood face 4") {
                settle(2)
                shot("40-mood-after")
            }
            dismissSheet()
        }

        // The measurement form at rest: no check over it before a save.
        if tapLogTab(), tap(element("capture.picker.row.measurement"), "capture row measurement") {
            settle(2.5)
            shot("40-measure-before")
            dismissSheet()
        }
    }
}
