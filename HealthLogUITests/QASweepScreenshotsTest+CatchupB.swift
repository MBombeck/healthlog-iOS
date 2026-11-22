import XCTest

/// **Server 1.49.0 on the app side, part B, photographed** (#191).
///
/// Ernährung with the energy balance row, the energy balance page (today
/// running, an estimated day, a day without a balance left out), the
/// magnesium target refused with its allowed range, and the notification
/// matrix with the notable-value row, off. Fixtures: `CatchupBFixtures`.
/// Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_21u_catchupB() {
        boot(extra: ["-uitest-catchup-b"])
        settle(3)
        energyBalanceShots()
        targetRangeShot()
        notificationMatrixShot()
    }

    private func energyBalanceShots() {
        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.nutrition") else {
            note("21u: More row not present: nutrition")
            return
        }
        row.tap()
        settle(3)
        dismissHealthSheet()
        confirmHealthAlert()
        shot("21u-nutrients-energy-row")
        guard let balance = probe("nutrients.energyBalance.row") else {
            note("21u: energy balance row not found")
            return
        }
        balance.tap()
        settle(3)
        shotToEnd("21u-energy-balance")
        scrollUpToTop()
        goBack()
        settle(1)
    }

    /// On a fresh simulator refusing the Health sheet leaves the system's
    /// "später in der Health-App" alert with one OK; tap it, wherever it is
    /// hosted, so the pages behind it can be photographed and left.
    private func confirmHealthAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 3 {
            var tapped = false
            for owner in [app, springboard] {
                let ok = owner.alerts.buttons["OK"].firstMatch
                if ok.exists, ok.isHittable {
                    ok.tap()
                    tapped = true
                    settle(1.5)
                }
            }
            if !tapped { return }
            dismissHealthSheet()
        }
    }

    private func targetRangeShot() {
        guard let nutrient = probe("nutrients.row.magnesium") else {
            note("21u: nutrient row not found: magnesium")
            return
        }
        nutrient.tap()
        settle(3)
        let edit = element("nutrients.detail.personalTarget.edit")
        for _ in 0 ..< 6 where !(edit.exists && edit.isHittable) {
            scrollDown()
        }
        guard edit.exists else {
            note("21u: personal target row not found")
            return
        }
        edit.tap()
        settle(2)
        let field = element("nutrients.target.editor.value")
        guard field.waitForExistence(timeout: 4) else {
            note("21u: target value field not found")
            return
        }
        field.tap()
        field.typeText("90000")
        guard tap(element("hl.sheet.confirm"), "target save") else { return }
        settle(2)
        shot("21u-nutrient-target-range")
        leaveEditedSheet()
    }

    /// The editor holds a typed value, so its cross asks first; take the
    /// discard answer, then step back to the nutrient list.
    private func leaveEditedSheet() {
        if tap(element("hl.sheet.close"), "target close", timeout: 3) {
            settle(1)
            let discard = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "verwerf", "discard", "negeer"
            )).firstMatch
            if discard.waitForExistence(timeout: 2), discard.isHittable {
                discard.tap()
            }
            settle(1.5)
        } else {
            dismissSheet()
        }
        goBack()
        settle(1)
    }

    private func notificationMatrixShot() {
        guard openSettings() else { return }
        guard let notifications = probe("settings.hub.notifications") else {
            note("21u: notifications entry not found")
            return
        }
        notifications.tap()
        settle(3)
        shotToEnd("21u-notifications-matrix")
    }
}
