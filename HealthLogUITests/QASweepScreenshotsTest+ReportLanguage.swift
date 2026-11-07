import XCTest

/// 1.5 L10N-REPORT — the report language under "Advanced" on the sharing
/// screen: the PDF form with the closed link, the open picker, and its menu.
/// Runs with the sweep's language, appearance and text size. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19r_reportLanguage() {
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.share"], "share glyph") else { return }
        waitFor("sharing.unified.produce", 15)
        settle(3)
        guard let pdf = probe("sharing.unified.form.pdf") else {
            note("PDF form row not present")
            return
        }
        pdf.tap()
        settle(2)
        guard let advanced = probe("sharing.unified.advanced") else {
            note("Advanced link not present")
            return
        }
        // One more drag so the open picker has room under the link.
        scrollDown()
        shot("19r-report-language-closed")
        advanced.tap()
        settle(2)
        shot("19r-report-language-open")
        if let picker = probe("sharing.unified.reportLanguage") {
            picker.tap()
            settle(2)
            shot("19r-report-language-menu")
        } else {
            note("report language picker not present")
        }
    }
}
