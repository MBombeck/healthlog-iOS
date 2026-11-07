import XCTest

/// **LAB-OCR (1.5.0, #149 item 3) — the lab-report scan read by the
/// server, photographed.**
///
/// More › Labs › + › Scan: the chooser with "Genauer lesen lassen" off and on
/// (`-uitest-lab-ocr`), then, relaunched with `-uitest-lab-ocr-review`, the
/// review list of a read that ran into limits (see `LabOCRFixtures`). Runs at
/// the accessibility size too. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_21_labOCR() {
        let size = isXXL ? "-xxl" : ""
        boot(extra: ["-uitest-lab-ocr"])
        if openScanSheet() {
            shot("21-labocr-chooser-off\(size)")
            let toggle = app.switches.firstMatch
            if toggle.waitForExistence(timeout: 4) {
                toggle.tap()
                settle(1.5)
                shot("21-labocr-chooser-on\(size)")
            } else {
                note("lab ocr: switch not found")
            }
        }

        app.terminate()
        boot(extra: ["-uitest-lab-ocr", "-uitest-lab-ocr-review"])
        guard openScanSheet() else { return }
        shot("21-labocr-review-top\(size)")
        for page in 1 ... 3 {
            scrollDown()
            shot("21-labocr-review-\(page)\(size)")
        }
    }

    /// More › Labs › + › "Laborbericht scannen".
    private func openScanSheet() -> Bool {
        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.labs") else {
            note("lab ocr: More row not present: labs")
            return false
        }
        row.tap()
        settle(3)
        guard let add = probe("labs.toolbar.add") else {
            note("lab ocr: add menu not found")
            return false
        }
        add.tap()
        settle(1)
        guard let scan = probe("labs.menu.scan") else {
            note("lab ocr: scan item not found")
            return false
        }
        scan.tap()
        settle(3)
        return true
    }
}
