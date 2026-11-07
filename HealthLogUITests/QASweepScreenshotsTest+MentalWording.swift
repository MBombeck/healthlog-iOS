import XCTest

/// L10N-MH — the questionnaire text from the server, per language: the SCI
/// with HealthLog's own translation (note and the centred switch), the same
/// step after the switch to the English original, and the first PHQ-9 step
/// with its stem. Runs with the sweep's language, appearance and text size.
extension QASweepScreenshotsTest {
    func test_16w_mentalHealthWording() {
        boot(extra: ["-uitest-area-meds"])
        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.mental_wellbeing") else {
            note("More row not present: mental_wellbeing")
            return
        }
        row.tap()
        settle(3)

        if let sci = probe("mentalHealth.choose.sci") {
            sci.tap()
            settle(2)
            shotToEnd("16w-sci-form")
            if let toggle = probe("mentalHealth.wording.toggle") {
                toggle.tap()
                settle(1.5)
                shotToEnd("16w-sci-original")
            } else {
                note("no wording switch on the SCI form (validated in this language)")
            }
            if tap(element("mentalHealth.abort"), "abort SCI") {
                settle(1.5)
            }
        }

        scrollUpToTop()
        guard let phq9 = probe("mentalHealth.choose.phq9") else { return }
        phq9.tap()
        settle(2)
        shotToEnd("16w-phq9-form")
    }
}
