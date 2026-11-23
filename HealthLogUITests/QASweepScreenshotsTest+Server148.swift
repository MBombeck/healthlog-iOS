import XCTest

/// **Server 1.48 on the app side, photographed** (#176, #182, #184).
///
/// Today with the medication card naming the doses still ahead, the steps
/// tile without its arrow (`trendWindowDays: null`) and the hero lead that
/// passes over an English reaction line; the weight page with the month
/// comparison from `/api/analytics/range`; the magnesium page with its
/// personal target and the target editor. Fixtures: `Server148Fixtures`.
/// Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_21s_server148() {
        boot(extra: ["-uitest-server148"])
        settle(3)
        shot("21s-today-top")
        let doses = element("dashboard.compliance.nextDoses")
        for _ in 0 ..< 8 where !(doses.exists && doses.isHittable) {
            scrollDown()
        }
        if !doses.exists { note("21s: next doses line not on Today") }
        shot("21s-today-medication")
        shotToEnd("21s-today")
        scrollUpToTop()

        openDeepLink("healthlog://insights/weight")
        settle(5)
        shotPair("21s-metric-weight")
        scrollUpToTop()

        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.nutrition") else {
            note("21s: More row not present: nutrition")
            return
        }
        row.tap()
        settle(3)
        dismissHealthSheet()
        shot("21s-nutrients")
        guard let nutrient = probe("nutrients.row.magnesium") else {
            note("21s: nutrient row not found: magnesium")
            return
        }
        nutrient.tap()
        settle(3)
        let edit = element("nutrients.detail.personalTarget.edit")
        for _ in 0 ..< 6 where !(edit.exists && edit.isHittable) {
            scrollDown()
        }
        shot("21s-nutrient-magnesium-target")
        guard edit.exists else {
            note("21s: personal target row not found")
            return
        }
        edit.tap()
        settle(2)
        shot("21s-nutrient-target-editor")
    }
}
