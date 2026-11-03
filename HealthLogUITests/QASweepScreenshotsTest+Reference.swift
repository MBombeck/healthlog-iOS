import XCTest

/// **iOS 1.4 B2 — the info pattern's reference screens, photographed whole.**
///
/// Today and the blood-pressure, sleep and oxygen metric pages, each scrolled from the
/// top to its end, plus the page's info sheet where the page has one. The area
/// units of B2 take the same before-and-after pictures of their own screens, so
/// the walk stops on its own once a scroll no longer moves the content instead
/// of guessing a fixed page length. Like the rest of the sweep it only runs
/// when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_13_infoPatternReference() {
        guard !isXXL else { return }
        boot()
        shotToEnd("13-today")
        // Oxygen carries the longest German title of the sweep pages, the
        // width check for the header circles.
        let pages = [("blood-pressure", "bloodPressure"), ("sleep", "sleep"), ("oxygen", "oxygenSaturation")]
        for (slug, kind) in pages {
            openDeepLink("healthlog://insights/\(slug)")
            settle(5)
            scrollUpToTop()
            shotToEnd("13-\(slug)")
            scrollUpToTop()
            // The pager keeps its neighbours alive: ask for this page's (i).
            let info = app.buttons["insights.metric.info.\(kind)"]
            guard info.waitForExistence(timeout: 3), info.isHittable else {
                note("\(slug): no info button on the page")
                continue
            }
            info.tap()
            settle(2.5)
            shot("13-\(slug)-info-top")
            scrollDown()
            shot("13-\(slug)-info-scroll1")
            dismissSheet()
        }
    }

    /// The screen from where it stands down to its end: one shot, then one per
    /// scroll until a scroll leaves the picture unchanged (at most ten).
    func shotToEnd(_ name: String) {
        shot("\(name)-top")
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        for step in 1 ... 10 {
            scrollDown()
            let current = XCUIScreen.main.screenshot().pngRepresentation
            if current == previous { break }
            previous = current
            shot("\(name)-scroll\(step)")
        }
    }
}
