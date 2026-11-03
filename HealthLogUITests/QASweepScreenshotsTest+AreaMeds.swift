import XCTest

/// **iOS 1.4 B2-b — medications, mood, mental health, cycle, illness and
/// notifications, photographed whole.**
///
/// The area unit's before-and-after pictures: every screen it tidies, scrolled
/// from the top to its end, plus the sheets those screens open. The marketing
/// world carries the medications; `-uitest-area-meds` (`AreaMedsFixtures`)
/// adds a medication kept as a record, thirty days of mood with the server's
/// relations and two PHQ-9 results. Navigation is soft like the rest of the
/// sweep. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_16a_areaMedications() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-area-meds"])
        tab("pills.fill")
        shotToEnd("16-meds-list")
        for (id, slug) in [
            ("mkshot-med-trulicity", "glp1"),
            ("mkshot-med-lisinopril", "daily"),
            ("area-med-metformin", "recordonly")
        ] {
            scrollUpToTop()
            guard let card = probe("medications.card.\(id)") else {
                note("medication card not found: \(id)")
                continue
            }
            card.tap()
            settle(3.5)
            shotToEnd("16-meds-detail-\(slug)")
            scrollUpToTop()
            if slug == "glp1" { editSheet() }
            goBack()
        }
        scrollUpToTop()
        if tap(element("medications.header.addButton"), "add medication") {
            settle(2)
            dropKeyboard()
            shotToEnd("16-meds-add")
            let advanced = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR label == %@", "Advanced options", "Erweiterte Optionen"
            )).firstMatch
            if tap(advanced, "advanced options") {
                settle(1.5)
                shotToEnd("16-meds-add-advanced")
            }
            dismissSheet()
        }
        scrollUpToTop()
        if tap(element("medications.header.customizeButton"), "customize") {
            settle(2)
            shot("16-meds-customize")
            dismissSheet()
        }
        intakeSheets()
    }

    private func editSheet() {
        let edit = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Edit", "Bearbeiten")
        ).firstMatch
        guard tap(edit, "Edit button on detail") else { return }
        settle(2)
        dropKeyboard()
        shotToEnd("16-meds-edit")
        dismissSheet()
    }

    /// The medication and reminder editors focus their first field when they
    /// settle, and the keyboard would cover everything below it. Submitting
    /// walks the editor's own chain (name, dose, done) without changing a
    /// value; the reminder's field only ends editing.
    private func dropKeyboard() {
        for _ in 0 ..< 2 where app.keyboards.firstMatch.exists {
            app.typeText("\n")
            settle(0.8)
        }
    }

    private func intakeSheets() {
        let log = app.tabBars.buttons.containing(.image, identifier: "plus.circle.fill").firstMatch
        guard tap(log, "Log tab") else { return }
        settle(2)
        guard tap(element("capture.picker.row.medication"), "capture row medication") else { return }
        settle(2.5)
        shot("16-meds-quick")
        if let freeLog = probe("meds.quick.freelog") {
            freeLog.tap()
            settle(2)
            shotToEnd("16-meds-freelog")
        }
        dismissSheet()
        dismissSheet()
    }

    func test_16b_areaMoodAndMentalHealth() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-area-meds"])
        openDeepLink("healthlog://insights/mood")
        settle(6)
        scrollUpToTop()
        // B4-z — the mood chart sits under the middle drag and takes it as a
        // scrub; the page is walked from the right gutter.
        scrollColumn = 0.98
        shotToEnd("16-mood-page")
        if let all = probe("insights.mood.showAll") {
            all.tap()
            settle(3)
            shot("16-mood-history")
            goBack()
        }
        scrollColumn = 0.5

        tab("ellipsis")
        scrollUpToTop()
        guard let row = probe("more.row.mental_wellbeing") else {
            note("More row not present: mental_wellbeing")
            return
        }
        row.tap()
        settle(3)
        shotToEnd("16-mental-choose")
        for instrument in ["phq9", "who5"] {
            scrollUpToTop()
            guard let detail = probe("mentalHealth.detail.\(instrument)") else { continue }
            detail.tap()
            settle(2.5)
            shotToEnd("16-mental-detail-\(instrument)")
            dismissSheet()
        }
        scrollUpToTop()
        guard let start = probe("mentalHealth.choose.phq9") else { return }
        start.tap()
        settle(2)
        shot("16-mental-form")
        for index in 0 ..< 20 {
            let option = element("mentalHealth.item.\(index).option.0")
            guard option.waitForExistence(timeout: 4), option.isHittable else { break }
            option.tap()
            settle(0.6)
        }
        shot("16-mental-form-functional")
        let functional = element("mentalHealth.functional.option.0")
        if functional.waitForExistence(timeout: 4), functional.isHittable {
            functional.tap()
            settle(1)
        }
        if tap(element("mentalHealth.submit"), "check-in submit") {
            settle(4)
            shotToEnd("16-mental-result")
        }
    }

    func test_16c_areaCycle() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-area-meds", "-hl.settings.cycleTracking.optIn", "YES"])
        // 1.4 B4 — the cycle opt-in can raise a second Health sheet right
        // after the first (the late read types); the tab bar is behind both.
        // B4-z: under load the second sheet arrives late, so wait until the
        // tab bar is reachable again instead of three quick tries.
        let more = app.tabBars.buttons.containing(.image, identifier: "ellipsis").firstMatch
        for _ in 0 ..< 8 {
            dismissHealthAuthorization()
            settle(1.5)
            if more.exists, more.isHittable { break }
        }
        tab("ellipsis")
        dismissHealthAuthorization()
        if let cycle = probe("more.row.cycle") {
            cycle.tap()
            settle(4)
            dismissHealthAuthorization()
            shotToEnd("16-cycle-home")
            scrollUpToTop()
            if tap(element("cycle.home.advancedSettings"), "cycle settings") {
                settle(2)
                shotToEnd("16-cycle-settings")
                dismissSheet()
            }
            infoSheet("cycle.info", "16-cycle-info")
            let log = app.tabBars.buttons.containing(.image, identifier: "plus.circle.fill").firstMatch
            if tap(log, "Log tab"), tap(element("capture.picker.row.cycle"), "capture row cycle") {
                settle(2.5)
                shotToEnd("16-cycle-capture")
                dismissSheet()
            }
            goBack()
        } else {
            note("Cycle: More row not present under opt-in")
        }
    }

    func test_16d_areaIllnessAndNotifications() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-area-meds"])
        tab("ellipsis")
        if let illness = probe("more.row.illness") {
            illness.tap()
            settle(3)
            shotToEnd("16-illness-journal")
            illnessSheet(opening: "illness.toolbar.add", "16-illness-add-top")
            for (label, slug) in [("Bronchitis", "active"), ("Influenza", "resolved")] {
                scrollUpToTop()
                guard tap(app.staticTexts[label].firstMatch, "illness episode \(label)") else { continue }
                settle(3)
                shotToEnd("16-illness-episode-\(slug)")
                if slug == "active" { illnessSheet(opening: "illness.detail.logDay", "16-illness-logday-top") }
                goBack()
            }
            scrollUpToTop()
            if tap(element("illness.toolbar.insights"), "illness insights") {
                settle(3)
                shot("16-illness-insights")
                goBack()
            }
            goBack()
        } else {
            note("More row not present: illness")
        }
        scrollUpToTop()
        if let vorsorge = probe("more.row.vorsorge") {
            vorsorge.tap()
            settle(3)
            shotToEnd("16-vorsorge")
            scrollUpToTop()
            if tap(element("MeasurementRemindersScreen.create"), "create reminder") {
                settle(2)
                dropKeyboard()
                shotToEnd("16-vorsorge-create")
                dismissSheet()
            }
            goBack()
        }
        scrollUpToTop()
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        guard let notifications = probe("settings.hub.notifications") else { return }
        notifications.tap()
        settle(3)
        shotToEnd("16-notifications")
        scrollUpToTop()
        infoSheet("notifications.info", "16-notifications-info")
        if let diagnostics = probe("notifications.diagnostics.entry") {
            diagnostics.tap()
            settle(3)
            shotToEnd("16-notifications-diagnostics")
            scrollUpToTop()
            infoSheet("notifications.diagnostics.info", "16-notifications-diagnostics-info")
            goBack()
        }
    }

    /// 1.4 B4-z — the two illness sheets whose German titles sit close to the
    /// width between "Abbrechen" and "Speichern" ("Neue Episode", "Tag
    /// eintragen"); no walk had opened them before.
    private func illnessSheet(opening identifier: String, _ name: String) {
        scrollUpToTop()
        guard let button = probe(identifier) else {
            note("illness sheet button not found: \(identifier)")
            return
        }
        button.tap()
        settle(2)
        dropKeyboard()
        shot(name)
        dismissSheet()
    }

    /// The screen's (i), when it has one: the sheet from its top and once more
    /// after a scroll. Before the unit there is none, which the notes record.
    private func infoSheet(_ identifier: String, _ name: String) {
        let info = app.buttons[identifier]
        guard info.waitForExistence(timeout: 3), info.isHittable else {
            note("no info button: \(identifier)")
            return
        }
        info.tap()
        settle(2.5)
        shotPair(name)
        dismissSheet()
    }
}
