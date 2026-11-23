import XCTest

/// **#186 — "Symptom erfassen" on Today, photographed.**
///
/// Today's quick-actions card at the end of the tiles with its new row above
/// "Dashboard anpassen", then the page it opens: the symptoms of
/// `SymptomFixtures` as chips, nothing linked. Only runs when `HL_SWEEP_OUT`
/// is set.
extension QASweepScreenshotsTest {
    func test_21t_symptomFromToday() {
        boot(extra: ["-uitest-area-meds", "-uitest-symptom", "-hl.healthkit.serverVersion", "1.48.4"])
        let row = element("dashboard.quickAction.symptom")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            scrollDown()
        }
        guard row.exists else {
            note("21t: symptom row not on Today")
            return
        }
        shot("21t-today-quickactions")
        row.tap()
        settle(3)
        shot("21t-symptom-entry")
        if let chip = probe("symptoms.chip.sym-cough") {
            chip.tap()
            settle(1)
            shot("21t-symptom-entry-picked")
        } else {
            note("21t: chip sym-cough not found")
        }
    }
}
