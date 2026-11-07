import XCTest

/// **MED-PLUS (1.5.0, #126 3.4 and 3.11) — courses and automatic
/// recording, photographed.**
///
/// Opens Lisinopril (`-uitest-area-meds`), which under `-uitest-med-plus`
/// (`MedPlusFixtures`) records its doses automatically and has two courses:
/// the dose line ("erinnert nicht"), the course list under "Erweitert", the
/// correction page of the ended course with its delete question, and the
/// editor with the switch. `test_22_medPlusOlderServer` runs the same walk
/// without the fields, which is also the "before" picture. Runs at the
/// accessibility size too (`HL_SWEEP_XXL=1`). Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_22_medPlus() {
        medPlusWalk(extra: [MedPlusSweep.argument], prefix: "22-medplus")
    }

    func test_22_medPlusOlderServer() {
        medPlusWalk(extra: [], prefix: "22-medplus-olderServer")
    }

    private func medPlusWalk(extra: [String], prefix: String) {
        boot(extra: ["-uitest-area-meds"] + extra)
        let size = isXXL ? "-xxl" : ""
        tab("pills.fill")
        guard let card = probe("medications.card.\(MedPlusSweep.medicationID)") else {
            note("medication card not found: \(MedPlusSweep.medicationID)")
            return
        }
        card.tap()
        settle(3.5)
        shot("\(prefix)-detail-top\(size)")
        let advanced = element("med.courses.advanced")
        for _ in 0 ..< 10 where !(advanced.exists && advanced.isHittable) {
            scrollDown()
        }
        if advanced.exists, advanced.isHittable {
            advanced.tap()
            settle(2.5)
            scrollDown()
            shot("\(prefix)-courses\(size)")
            if tap(element("med.courses.row.\(MedPlusSweep.endedCourseID)"), "ended course") {
                settle(2)
                shot("\(prefix)-course-edit\(size)")
                if tap(element("med.courses.edit.delete"), "delete course") {
                    settle(1)
                    shot("\(prefix)-course-delete-ask\(size)")
                }
                goBack()
                settle(1.5)
            }
        } else {
            note("no course section on \(prefix)")
            shot("\(prefix)-detail-end\(size)")
        }
        scrollUpToTop()
        let edit = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Edit", "Bearbeiten")
        ).firstMatch
        guard tap(edit, "Edit button on detail") else { return }
        settle(2)
        for _ in 0 ..< 2 where app.keyboards.firstMatch.exists {
            app.typeText("\n")
            settle(0.8)
        }
        let advancedRow = element("med.edit.advanced")
        for _ in 0 ..< 12 where !(advancedRow.exists && advancedRow.isHittable) {
            scrollDown()
        }
        let toggle = element("med.edit.autoMarkTaken")
        if advancedRow.exists, !toggle.exists {
            note("auto-mark switch folded on \(prefix)")
            advancedRow.tap()
            settle(1)
        }
        for _ in 0 ..< 12 where !(toggle.exists && toggle.isHittable) {
            scrollDown()
        }
        if !toggle.exists { note("no auto-mark switch on \(prefix)") }
        shot("\(prefix)-edit\(size)")
        dismissSheet()
    }
}

private enum MedPlusSweep {
    static let argument = "-uitest-med-plus"
    static let medicationID = "mkshot-med-lisinopril"
    static let endedCourseID = "medplus-course-1"
}
