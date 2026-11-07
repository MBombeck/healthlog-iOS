import XCTest

/// **SUPP (1.5.0, #131) — a supplement's composition and the nutrient
/// split, photographed.**
///
/// Opens the supplement "Vitamin D3" (`-uitest-area-meds -uitest-supp`, see
/// `SuppFixtures`) and shoots its composition card, then walks More ›
/// nutrients into vitamin D (all from the supplement), magnesium (two sources,
/// the supplement share above its upper limit) and DHA. Runs at the
/// accessibility size too (`HL_SWEEP_XXL=1`). Navigation is soft like the rest
/// of the sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_20_supp() {
        boot(extra: ["-uitest-area-meds", "-uitest-supp"])
        let size = isXXL ? "-xxl" : ""
        tab("pills.fill")
        if let card = probe("medications.card.supp-med-d3") {
            card.tap()
            settle(3.5)
            shot("20-supp-med\(size)-top")
            let section = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'medications.composition'")).firstMatch
            for _ in 0 ..< 10 where !(section.exists && section.isHittable) {
                scrollDown()
            }
            if !section.exists { note("no composition section") }
            shot("20-supp-med\(size)-composition")
            goBack()
            settle(1)
        } else {
            note("medication card not found: supp-med-d3")
        }

        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.nutrition") else {
            note("More row not present: nutrition")
            return
        }
        row.tap()
        settle(3)
        dismissHealthSheet()
        shot("20-supp-nutrients\(size)")
        for code in ["vitamin_d", "magnesium", "dha"] {
            guard let nutrient = probe("nutrients.row.\(code)") else {
                note("nutrient row not found: \(code)")
                continue
            }
            nutrient.tap()
            settle(3)
            shot("20-supp-nutrient-\(code)\(size)")
            goBack()
            settle(1)
        }
    }

    /// The nutrient page's first visit raises the dietary Health sheet, which
    /// can arrive after the shared helper looked. Look a few times, by label
    /// in any language the sweep runs, in the app and in SpringBoard.
    ///
    /// POLISH-A A7 — iOS 26.5 may raise no sheet at all, or one that is gone by
    /// the time the button is read again. The label is read before the tap
    /// (reading it after re-resolves a button that no longer exists and fails
    /// the test), and a list that is already reachable ends the search without
    /// any tap by position.
    private func dismissHealthSheet() {
        let refuse = NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
            "Don", "Nicht", "Niet"
        )
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 8 {
            for owner in [app, springboard] {
                let button = owner.buttons.matching(refuse).firstMatch
                guard button.exists else { continue }
                if button.isHittable {
                    let label = button.label
                    button.tap()
                    settle(2)
                    note("dismissed the Health sheet (\(label))")
                    return
                }
                // Below the sheet's fold: bring it up, look again.
                owner.swipeUp()
            }
            settle(1.5)
        }
        if nutrientListReachable() {
            note("no Health sheet in the app's tree, nutrient list reachable")
            return
        }
        // iOS 27 hosts the sheet out of process: its buttons are not in the
        // tree. Either answer dismisses it, so scroll to its end and tap where
        // the two answers sit, until the list behind it is reachable again.
        let window = app.windows.firstMatch
        for _ in 0 ..< 8 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        settle(1)
        shot("20-supp-healthsheet-end")
        for dy in [0.85, 0.78, 0.9] where !element("nutrients.water.total").isHittable {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
            settle(2)
        }
        note("Health sheet answered by position: \(element("nutrients.water.total").isHittable)")
    }

    /// The nutrient list is on screen and not covered by a sheet.
    private func nutrientListReachable() -> Bool {
        if element("nutrients.water.total").isHittable { return true }
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'nutrients.row.'")).firstMatch
        return row.exists && row.isHittable
    }
}
