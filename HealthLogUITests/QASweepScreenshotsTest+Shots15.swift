import XCTest

/// **SHOTS (1.5.0) — the surfaces no earlier walk photographed whole.**
///
/// `test_24a` is the blood pressure page with everything 1.5 can put on it at
/// once (lab line, part of day, usual range, time of day), its part-of-day
/// menu open, the weight page and the Insights overview, each from the top to
/// its end. `test_24b` is LAB-DOC: the labs list, a marker without a unit,
/// its editor; `test_24c` a single reading and the add sheet with the "No unit" switch off
/// and on; `test_24d` a scanned report whose read stopped early. All run at every
/// text size of the sweep (`HL_SWEEP_XXL`, `HL_SWEEP_XXL_SIZE`). Navigation is
/// soft like the rest of the sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_24a_metricPageEverything() {
        let size = isXXL ? "-xxl" : ""
        boot(extra: [
            "-uitest-lab-lines",
            "-uitest-bp-tod",
            "-hl.healthkit.serverVersion", "1.47.0",
            "-insights.labOverlay.bloodPressure", "lab:bm_hba1c",
            "-insights.labOverlay.weight", "lab:bm_hba1c"
        ])
        openDeepLink("healthlog://insights/blood-pressure")
        settle(6)
        scrollColumn = 0.96
        shotToEnd("24a-bp-all\(size)")
        scrollUpToTop()
        if let advanced = onScreen("insights.metric.advanced") {
            advanced.tap()
            settle(2)
            if openMenu(["Ganzer Tag", "Whole day"]) {
                shot("24a-bp-partOfDay-menu\(size)")
                chooseMenuItem(["Morgens", "Morning"])
                settle(4)
                scrollUpToTop()
                shot("24a-bp-morning\(size)")
            }
        } else {
            note("24a: Advanced link not on screen (blood pressure)")
        }
        scrollUpToTop()
        openDeepLink("healthlog://insights/weight")
        settle(6)
        shotToEnd("24a-weight-all\(size)")
        scrollColumn = 0.5
        scrollUpToTop()
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        settle(3)
        shotToEnd("24a-insights-overview\(size)")
    }

    func test_24b_labDoc() {
        let size = isXXL ? "-xxl" : ""
        guard openLabs() else { return }
        shotToEnd("24b-labs-list\(size)")
        scrollUpToTop()
        let inr = app.buttons.matching(NSPredicate(format: "identifier == 'labs.byType.item' AND label CONTAINS 'INR'")).firstMatch
        guard tap(inr, "INR marker row") else { return }
        settle(3)
        shotToEnd("24b-labs-marker-inr\(size)")
        scrollUpToTop()
        if tap(element("biomarker.detail.gear"), "marker gear") {
            settle(2)
            shotToEnd("24b-labs-marker-editor\(size)")
        }
    }

    /// LAB-DOC: one reading from the chronological list, then the add sheet
    /// with the "No unit" switch off and on. A fresh launch, so a sheet the
    /// marker walk left open cannot block it.
    func test_24c_labReadingAndAdd() {
        let size = isXXL ? "-xxl" : ""
        guard openLabs() else { return }
        let sort = app.segmentedControls.firstMatch
        if sort.waitForExistence(timeout: 4) {
            sort.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
            settle(2)
            shot("24b-labs-chronological\(size)")
            let reading = app.buttons.matching(NSPredicate(format: "label CONTAINS 'INR'")).firstMatch
            if tap(reading, "INR reading row") {
                settle(3)
                shotToEnd("24b-labs-reading-inr\(size)")
                goBack()
                settle(1.5)
            }
        } else {
            note("24c: sort switch not found")
        }
        scrollUpToTop()
        guard tap(element("labs.toolbar.add"), "labs add menu"), tap(element("labs.menu.add"), "add result") else { return }
        settle(2)
        shot("24b-labs-add-top\(size)")
        let toggle = element("labs.unit.none")
        for _ in 0 ..< 6 where !(toggle.exists && toggle.isHittable) {
            scrollDown()
        }
        shot("24b-labs-add-unit-off\(size)")
        if toggle.exists, toggle.isHittable {
            toggle.tap()
            settle(1)
            shot("24b-labs-add-unit-on\(size)")
        } else {
            note("24c: No unit switch not on the add sheet")
        }
    }

    /// LAB-DOC: a scanned report whose read stopped before the end.
    func test_24d_documentIncomplete() {
        let size = isXXL ? "-xxl" : ""
        boot(extra: ["-uitest-lab-doc", "-hl.healthkit.serverVersion", "1.47.0"])
        tab("ellipsis")
        guard let documents = probe("more.row.documents") else {
            note("24d: More row not present: documents")
            return
        }
        documents.tap()
        settle(3)
        shot("24b-docs-list\(size)")
        guard tap(app.staticTexts["Laborbefund Oktober"].firstMatch, "incomplete document") else { return }
        settle(4)
        if probe("documents.detail.extractIncomplete") == nil { note("24d: incomplete line not on screen") }
        scrollUpToTop()
        shotToEnd("24b-doc-incomplete\(size)")
    }

    private func openLabs() -> Bool {
        boot(extra: ["-uitest-lab-doc", "-hl.healthkit.serverVersion", "1.47.0"])
        tab("ellipsis")
        guard let labs = probe("more.row.labs") else {
            note("24b: More row not present: labs")
            return false
        }
        labs.tap()
        settle(3)
        return true
    }

    /// The first element with this identifier that is on screen, scrolling
    /// down at most nine times (the pager keeps neighbouring pages alive).
    private func onScreen(_ identifier: String) -> XCUIElement? {
        for _ in 0 ..< 9 {
            let matches = app.descendants(matching: .any).matching(identifier: identifier)
            for index in 0 ..< matches.count {
                let candidate = matches.element(boundBy: index)
                if candidate.exists, candidate.isHittable { return candidate }
            }
            scrollDown()
        }
        return nil
    }

    private func openMenu(_ labels: [String]) -> Bool {
        for _ in 0 ..< 4 {
            for label in labels {
                let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", label, label)).firstMatch
                if button.exists, button.isHittable {
                    button.tap()
                    settle(1.5)
                    return true
                }
            }
            scrollDown()
        }
        note("24a: part-of-day menu not hittable")
        return false
    }

    private func chooseMenuItem(_ labels: [String]) {
        for label in labels {
            let item = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if item.exists, item.isHittable {
                item.tap()
                return
            }
        }
        note("24a: menu item not found: \(labels)")
    }
}
