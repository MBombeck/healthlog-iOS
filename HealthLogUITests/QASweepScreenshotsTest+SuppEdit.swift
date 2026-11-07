import XCTest

/// **SUPP-EDIT (1.5.0, #131 P3) — the composition form, photographed.**
///
/// Opens "Vitamin D3" (`-uitest-area-meds -uitest-supp -uitest-supp-edit`,
/// see `SuppEditFixtures`), shoots the link under the composition, the form
/// as it opens, and, in a second launch with `-uitest-supp-edit-label`, the
/// form after a label read (proposal, the unsure line, the unmatched line).
/// Runs at the accessibility size too (`HL_SWEEP_XXL=1`). Navigation is soft
/// like the rest of the sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_23_suppEdit() {
        let size = isXXL ? "-xxl" : ""
        for (pass, extra) in [("form", [String]()), ("label", ["-uitest-supp-edit-label"])] {
            if pass == "label" { app.terminate() }
            boot(extra: ["-uitest-area-meds", "-uitest-supp", "-uitest-supp-edit"] + extra)
            tab("pills.fill")
            guard let card = probe("medications.card.supp-med-d3") else {
                note("medication card not found: supp-med-d3")
                return
            }
            card.tap()
            settle(3.5)
            let link = element("medications.composition.edit")
            for _ in 0 ..< 12 where !(link.exists && link.isHittable) {
                scrollDown()
            }
            guard link.exists else {
                note("no edit link")
                shot("23-suppedit-\(pass)\(size)-nolink")
                return
            }
            if pass == "form" { shot("23-suppedit-link\(size)") }
            link.tap()
            settle(pass == "label" ? 5 : 3)
            shot("23-suppedit-\(pass)\(size)-top")
            scrollDown()
            settle(1)
            shot("23-suppedit-\(pass)\(size)-rows")
            scrollDown()
            settle(1)
            shot("23-suppedit-\(pass)\(size)-end")
        }
    }
}
