import XCTest

/// **SYMPTOM (1.5.0, #144) — symptoms on an illness episode, photographed.**
///
/// Opens the open Bronchitis (`-uitest-area-meds`), whose symptoms come from
/// `SymptomFixtures` under `-uitest-symptom`: the section with its three
/// filed rows (the unfiled headache inside the same days must be absent),
/// the edit page of the first row, the page that logs a new one, then the
/// resolved Influenza with its one row and no text link. Runs at the
/// accessibility size too (`HL_SWEEP_XXL=1`). Navigation is soft like the
/// rest of the sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_21s_symptom() {
        // The hermetic version probe records nothing during the walk; the
        // argument domain sets the version the section's gate reads.
        boot(extra: ["-uitest-area-meds", SymptomSweep.argument, "-hl.healthkit.serverVersion", "1.47.0"])
        let size = isXXL ? "-xxl" : ""
        tab("ellipsis")
        guard let illness = probe("more.row.illness") else {
            note("More row not present: illness")
            return
        }
        illness.tap()
        settle(3)
        for (label, slug) in [("Bronchitis", "active"), ("Influenza", "resolved")] {
            scrollUpToTop()
            guard tap(app.staticTexts[label].firstMatch, "illness episode \(label)") else { continue }
            settle(3.5)
            guard scrollToSection() else {
                // Without a section this is the page's end, the "before" picture.
                shot("21-symptom-\(slug)\(size)-section")
                goBack()
                continue
            }
            shot("21-symptom-\(slug)\(size)-section")
            if slug == "active" {
                if let row = probe("symptoms.row.sym-e1") {
                    row.tap()
                    settle(2)
                    shot("21-symptom-edit\(size)")
                    goBack()
                    settle(1)
                } else {
                    note("symptom row not found: sym-e1")
                }
                if let add = probe("symptoms.add") {
                    add.tap()
                    settle(2)
                    shot("21-symptom-create\(size)")
                    goBack()
                    settle(1)
                } else {
                    note("symptom add link not found")
                }
            }
            goBack()
            settle(1)
        }
    }

    /// A server before v1.43.4 ignores the `episodeId` filter: no section,
    /// the page as in 1.4 (also the "before" picture).
    func test_21s_symptomOlderServer() {
        boot(extra: ["-uitest-area-meds", SymptomSweep.argument, "-hl.healthkit.serverVersion", "1.43.3"])
        let size = isXXL ? "-xxl" : ""
        tab("ellipsis")
        guard let illness = probe("more.row.illness") else {
            note("More row not present: illness")
            return
        }
        illness.tap()
        settle(3)
        guard tap(app.staticTexts["Bronchitis"].firstMatch, "illness episode Bronchitis") else { return }
        settle(3.5)
        if element("symptoms.section").exists { note("older server shows a symptoms section") }
        shotToEnd("21-symptom-olderServer\(size)")
    }

    /// Scrolls until the section's card is on screen, then once more so the
    /// link under it shows too.
    private func scrollToSection() -> Bool {
        let section = element("symptoms.section")
        for _ in 0 ..< 8 where !(section.exists && section.isHittable) {
            scrollDown()
        }
        guard section.exists else {
            note("no symptoms section")
            return false
        }
        scrollDown()
        return true
    }
}

private enum SymptomSweep {
    static let argument = "-uitest-symptom"
}
