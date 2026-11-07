import XCTest

/// **iOS 1.4 B2-a — Today, Measurements and Insights, photographed whole.**
///
/// The area unit's before-and-after pictures: every screen it tidies, scrolled
/// from the top to its end, plus the sheets those screens open. Navigation is
/// soft like the rest of the sweep (a screen the fixture world cannot reach
/// writes a line to `_notes.txt`). Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_14_areaTodayMeasurementsInsights() {
        guard !isXXL else { return }
        boot()
        todayWalk()
        moreWalk()
        insightsWalk()
    }

    private func todayWalk() {
        shotToEnd("14-today")
        scrollUpToTop()
        if tap(element("dashboard.complianceRing.tap"), "compliance card") {
            settle(2.5)
            shotToEnd("14-today-intakes")
            dismissSheet()
        }
    }

    private func moreWalk() {
        tab("ellipsis")
        moreScreen("measurements", "14-measurements") {
            if self.tap(self.element("measurements.picker.row.weight"), "weight row") {
                self.settle(3)
                self.shotToEnd("14-measurements-weight")
                self.goBack()
            }
            self.scrollUpToTop()
            if self.tap(self.element("measurements.picker.modeSwitch"), "chrono switch") {
                self.settle(3)
                self.shotToEnd("14-measurements-chrono")
            }
        }
        // Nutrition last: its first visit raises the dietary Health sheet.
        for row in ["environment", "personal_records", "achievements", "workouts", "nutrition"] {
            moreScreen(row, "14-\(row)") {}
        }
    }

    /// The pages by deep link first; the overview last. Under load its
    /// animated score rings kept the main thread busy past XCUITest's 30 s
    /// snapshot limit, which ended the walk before the pages (seen twice on
    /// the base build).
    private func insightsWalk() {
        // 1.4 B4-a — blood pressure for its two-line chart and the date axis.
        for slug in ["medications", "workouts", "mood", "ecg", "sleep", "resting-pulse", "blood-pressure"] {
            openDeepLink("healthlog://insights/\(slug)")
            settle(5)
            scrollUpToTop()
            shotToEnd("14-insights-\(slug)")
        }
        metricSheet(slug: "weight", button: "insights.metric.targetEdit.weight", name: "14-target-editor")
        metricSheet(slug: "blood-pressure", button: "insights.metric.info.bloodPressure", name: "14-bp-info")
        openDeepLink("healthlog://insights")
        settle(5)
        scrollUpToTop()
        shotToEnd("14-insights-overview")
    }

    /// **1.4 B4-a — the chart lines of the medication-and-mood world.** The
    /// mood trend (its mean label, its date axis), the cycle's basal
    /// temperature and history charts (their y range, their date labels), the
    /// GLP-1 drug level and the PHQ-9 history (their date axes), on the
    /// `-uitest-area-meds` overlay; the screens themselves belong to B4-c.
    func test_18_b4a_chartLines() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-area-meds", "-hl.settings.cycleTracking.optIn", "YES"])
        dismissHealthAuthorization()
        openDeepLink("healthlog://insights/mood")
        settle(6)
        // The cycle opt-in asks Health for its categories on the first screen.
        dismissHealthAuthorization()
        scrollUpToTop()
        scrollColumn = 0.98 // B4-z — past the mood chart's scrub, see 16b
        shotToEnd("18-mood-page")
        scrollColumn = 0.5
        tab("ellipsis")
        dismissHealthAuthorization()
        scrollUpToTop()
        guard let cycle = probe("more.row.cycle") else {
            note("Cycle: More row not present under opt-in")
            return
        }
        cycle.tap()
        settle(4)
        dismissHealthAuthorization()
        shotToEnd("18-cycle-home")
        goBack()
        settle(1)
        scrollUpToTop()
        if let mental = probe("more.row.mental_wellbeing") {
            mental.tap()
            settle(3)
            if let detail = probe("mentalHealth.detail.phq9") {
                detail.tap()
                settle(2.5)
                shotToEnd("18-mental-phq9")
                dismissSheet()
            }
            goBack()
        }
        tab("pills.fill")
        scrollUpToTop()
        if let glp1 = probe("medications.card.mkshot-med-trulicity") {
            glp1.tap()
            settle(3.5)
            shotToEnd("18-meds-glp1")
        }
    }

    /// A metric page's header circle and the sheet it opens, to its end.
    private func metricSheet(slug: String, button: String, name: String) {
        openDeepLink("healthlog://insights/\(slug)")
        settle(5)
        scrollUpToTop()
        if tap(app.buttons[button], button) {
            settle(2.5)
            shotToEnd(name)
            dismissSheet()
        }
    }

    /// Today without a single medication: the plain hermetic world (no
    /// marketing overlay), where the adherence card has nothing to show.
    func test_15_todayWithoutMedications() {
        guard !isXXL else { return }
        app = XCUIApplication()
        let arguments = language.launchArguments + [
            "-uitest-phase8", "insightsAccessibility",
            "-uitest-sweep",
            "-hl.healthkit.requestedAt.hermetic-user", "true",
            "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
        ]
        app.launchHermeticAndWaitForDashboard(extraArguments: arguments, timeout: 120)
        settle(8)
        dismissOverlays()
        shotToEnd("15-today-nomeds")
    }

    /// A More row, photographed to its end; `then` runs on the open screen.
    private func moreScreen(_ row: String, _ name: String, then: () -> Void) {
        scrollUpToTop()
        guard let target = probe("more.row.\(row)") else {
            note("More row not present: \(row)")
            return
        }
        target.tap()
        settle(3)
        dismissHealthAuthorization()
        shotToEnd(name)
        scrollUpToTop()
        then()
        goBack()
        settle(1)
    }
}
