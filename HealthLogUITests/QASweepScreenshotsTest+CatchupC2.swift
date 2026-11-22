import XCTest

/// **#191 QoL — symptoms by use and the lab page.**
///
/// `test_c2a`: the Log tab's picker with "Symptom erfassen" after the mood
/// row, then the symptom page it opens on Today: the chips by use (the
/// headache, logged three times, ahead of the cough), and the headache
/// picked, its intensity set to the last one (5) with the hint under it.
/// `test_c2c`: a lab marker with its latest values under the
/// chart and Delete in the more menu. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_c2a_symptomFromCapture() {
        boot(extra: ["-uitest-area-meds", "-uitest-symptom", "-hl.healthkit.serverVersion", "1.48.4"])
        guard tapLogTab() else { return }
        settle(2)
        shot("c2a-capture-picker")
        guard tap(element("capture.picker.row.symptom"), "capture row symptom") else { return }
        settle(3)
        shot("c2a-symptom-by-use")
        guard let chip = probe("symptoms.chip.sym-headache") else {
            note("c2a: chip sym-headache not found")
            return
        }
        chip.tap()
        settle(1.5)
        if probe("symptoms.edit.intensityPreset") == nil { note("c2a: preset hint not on screen") }
        shot("c2a-symptom-preset")
    }

    func test_c2c_labLatestValues() {
        boot(extra: ["-uitest-lab-doc", "-hl.healthkit.serverVersion", "1.47.0"])
        guard openArea("labs") else { return }
        let inr = app.buttons.matching(NSPredicate(format: "identifier == 'labs.byType.item' AND label CONTAINS 'INR'")).firstMatch
        guard tap(inr, "INR marker row") else { return }
        settle(3)
        for _ in 0 ..< 6 where probe("biomarker.detail.latestValues") == nil {
            scrollDown()
        }
        shot("c2c-labs-latest-values")
        scrollUpToTop()
        if tap(element("biomarker.detail.gear"), "marker more menu") {
            settle(1.5)
            shot("c2c-labs-more-menu")
        }
    }
}
