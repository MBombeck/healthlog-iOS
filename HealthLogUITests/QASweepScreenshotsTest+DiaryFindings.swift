import XCTest

/// **Diary and findings, photographed where the other walks do not reach.**
///
/// The question before several documents are deleted at once, the mood tag
/// management, and the mood, cycle and illness screens at the accessibility
/// size (the area walks skip that size). Navigation is soft like the rest of
/// the sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    /// Two documents selected, then the bar's delete: the question names how
    /// many go. Cancelled, nothing is deleted.
    func test_29_docsBulkDeleteQuestion() {
        boot(extra: ["-uitest-docs-trash"])
        let size = isXXL ? "-xxl" : ""
        tab("ellipsis")
        guard let row = probe("more.row.documents") else {
            note("More row not present: documents")
            return
        }
        row.tap()
        settle(3)
        // Selecting sits in the list menu, beside the filter.
        guard tap(element("documents.toolbar.filter"), "list menu"),
              tap(element("documents.toolbar.select"), "select mode") else { return }
        settle(1)
        for title in ["Befund Hausarztpraxis", "Rezept Naproxen"] {
            _ = tap(app.staticTexts[title].firstMatch, "document \(title)")
            settle(0.5)
        }
        shot("29-docs-bulk-selected\(size)")
        guard tap(element("documents.bulk.delete"), "bulk delete") else { return }
        settle(1.5)
        shot("29-docs-bulk-delete-question\(size)")
        let cancel = app.alerts.buttons.element(boundBy: 0)
        if cancel.exists { cancel.tap() }
        settle(1)
    }

    /// The tag management, reached from the mood sheet after a face is tapped.
    func test_29_moodTagManagement() {
        boot()
        let size = isXXL ? "-xxl" : ""
        guard tapLogTab(), tap(element("capture.picker.row.mood"), "capture row mood") else { return }
        settle(2.5)
        let face = app.buttons.matching(NSPredicate(format: "label IN %@", ["Gut", "Good", "Goed"])).firstMatch
        if face.waitForExistence(timeout: 4) {
            face.tap()
        } else {
            note("mood face not found")
            return
        }
        settle(3)
        shot("29-mood-annotate\(size)")
        guard let manage = probe("mood.annotate.manageTags") else {
            note("tag management link not found")
            return
        }
        manage.tap()
        settle(3)
        shotToEnd("29-mood-tags\(size)")
    }

    /// The mood page at the size the area walks leave out.
    func test_29_moodLargeType() {
        guard isXXL else {
            expectsNoPicture = true
            return
        }
        boot()
        openDeepLink("healthlog://insights/mood")
        settle(6)
        scrollUpToTop()
        shotToEnd("29-mood-page-xxl")
    }

    /// The illness journal and its add sheet at the size the area walks
    /// leave out. Booted without the cycle opt-in, which raises Health sheets.
    func test_29_illnessLargeType() {
        guard isXXL else {
            expectsNoPicture = true
            return
        }
        boot(extra: ["-uitest-area-meds"])
        tab("ellipsis")
        guard let illness = probe("more.row.illness") else {
            note("More row not present: illness")
            return
        }
        illness.tap()
        settle(3)
        shotToEnd("29-illness-journal-xxl")
        if tap(element("illness.toolbar.add"), "illness add") {
            settle(2)
            shot("29-illness-add-xxl")
            dismissSheet()
        }
    }

    /// The cycle home and its settings, in every size. The opt-in raises one
    /// or two Health sheets; what stands in front of the tab bar is
    /// photographed when it does not go away.
    func test_29_cycle() {
        let size = isXXL ? "-xxl" : ""
        boot(extra: ["-uitest-area-meds", "-hl.settings.cycleTracking.optIn", "YES"])
        let more = ShellNavigator.button(symbol: "ellipsis", in: app)
        for _ in 0 ..< 12 {
            answerHealthAccess()
            settle(2)
            if more.exists, more.isHittable { break }
        }
        // The Health sheet of this system shows its refusal only at the end
        // of a long list, or not at all; pulled down it closes as refused.
        for _ in 0 ..< 3 where !(more.exists && more.isHittable) {
            shot("29-cycle-blocker\(size)")
            app.swipeDown(velocity: .fast)
            settle(2)
            answerHealthAccess()
        }
        tab("ellipsis")
        answerHealthAccess()
        guard let cycle = probe("more.row.cycle") else {
            note("Cycle: More row not present under opt-in")
            return
        }
        cycle.tap()
        settle(4)
        answerHealthAccess()
        shotToEnd("29-cycle-home\(size)")
        scrollUpToTop()
        if tap(element("cycle.home.advancedSettings"), "cycle settings") {
            settle(2)
            shotToEnd("29-cycle-settings\(size)")
            dismissSheet()
        }
    }
}
