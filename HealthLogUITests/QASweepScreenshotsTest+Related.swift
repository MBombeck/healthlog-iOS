import XCTest

/// **RELATED (1.5.0, #141) — "Related" on four pages, photographed.**
///
/// Opens Metformin (`-uitest-area-meds`), whose single read carries `related`
/// under `-uitest-related` (`RelatedFixtures`), shoots the section and then
/// walks its rows into the lab value, the scanned report and the Influenza
/// episode, each of which has its own related list. Runs at the accessibility
/// size too (`HL_SWEEP_XXL=1`). Navigation is soft like the rest of the sweep.
/// Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19_related() {
        boot(extra: ["-uitest-area-meds", RelatedSweep.argument])
        let size = isXXL ? "-xxl" : ""
        tab("pills.fill")
        guard let card = probe("medications.card.area-med-metformin") else {
            note("medication card not found: area-med-metformin")
            return
        }
        card.tap()
        settle(3.5)
        sectionShot("19-related-med\(size)")
        for (kind, slug) in [("labResult", "lab"), ("document", "doc"), ("conditionEpisode", "episode")] {
            guard let row = probe("related.row.\(kind)") else {
                note("related row not found: \(kind)")
                continue
            }
            row.tap()
            settle(3.5)
            sectionShot("19-related-\(slug)\(size)")
            goBack()
            settle(1)
        }
    }

    /// POLISH-A — the list and header layouts the SHOTS sweep found cut at an
    /// accessibility size: the medication list and a medication's header, the
    /// lab list and a marker page (statistics row), the document list with its
    /// "Recently deleted" link. Same world as `test_19_related`, so it runs at
    /// any text size (`HL_SWEEP_XXL=1` for the accessibility size).
    func test_25a_polishLayouts() {
        boot(extra: ["-uitest-area-meds", RelatedSweep.argument])
        let size = isXXL ? "-xxl" : ""
        tab("pills.fill")
        shot("25a-meds\(size)-top")
        scrollDown()
        shot("25a-meds\(size)-scroll1")
        scrollUpToTop()
        if let card = probe("medications.card.area-med-metformin") {
            card.tap()
            settle(3.5)
            shot("25a-med-detail\(size)-top")
            goBack()
            settle(1)
        } else {
            note("25a: medication card not found")
        }
        tab("ellipsis")
        scrollUpToTop()
        if let labs = probe("more.row.labs") {
            labs.tap()
            settle(3)
            shot("25a-labs\(size)-top")
            let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs.byType.item'")).firstMatch
            if first.waitForExistence(timeout: 4), first.isHittable {
                first.tap()
                settle(3)
                shot("25a-labs-marker\(size)-top")
                scrollDown()
                shot("25a-labs-marker\(size)-scroll1")
                goBack()
                settle(1)
            } else {
                note("25a: no biomarker row")
            }
            goBack()
            settle(1)
        } else {
            note("25a: More row not present: labs")
        }
        scrollUpToTop()
        if let documents = probe("more.row.documents") {
            documents.tap()
            settle(3)
            shot("25a-documents\(size)-top")
            goBack()
        } else {
            note("25a: More row not present: documents")
        }
    }

    /// POLISH-A — the lab list and a marker page in the world that has lab
    /// values (`-uitest-citations`, as `test_17b_recordsArea`).
    func test_25b_polishLabs() {
        boot(extra: ["-uitest-citations"])
        let size = isXXL ? "-xxl" : ""
        tab("ellipsis")
        scrollUpToTop()
        guard let labs = probe("more.row.labs") else {
            note("25b: More row not present: labs")
            return
        }
        labs.tap()
        settle(3)
        shot("25b-labs\(size)-top")
        scrollDown()
        shot("25b-labs\(size)-scroll1")
        scrollUpToTop()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs.byType.item'")).firstMatch
        guard first.waitForExistence(timeout: 4), first.isHittable else {
            note("25b: no biomarker row")
            return
        }
        first.tap()
        settle(3)
        shot("25b-labs-marker\(size)-top")
        scrollDown()
        shot("25b-labs-marker\(size)-scroll1")
    }

    /// The page's top, then the section itself (scrolled into view).
    private func sectionShot(_ name: String) {
        shot("\(name)-top")
        let any = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'related.'")).firstMatch
        for _ in 0 ..< 8 where !(any.exists && any.isHittable) {
            scrollDown()
        }
        if any.exists {
            scrollDown()
        } else {
            note("no related section on \(name)")
        }
        // Without a section this is the page's end, the "before" picture.
        shot("\(name)-section")
        scrollUpToTop()
    }
}

private enum RelatedSweep {
    static let argument = "-uitest-related"
}
