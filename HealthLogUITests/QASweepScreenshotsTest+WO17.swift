import XCTest

/// iOS 1.7 (#164, #165, #182 A4/A5) against the 1.48 contract
/// (`-uitest-wo17`, `WO17Fixtures`): the seizure diary with the quick log
/// running past its threshold, a seizure's page, the types and the cluster
/// rule; the upcoming cycles under the forecast; the labs list grouped by the
/// person's choice with flagged groups open, and the panel suggestions in the
/// marker form; the guardian's reading switch above the vault; the seizure
/// lane and the hidden symptom on the timeline. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_42_seizures() {
        boot(extra: ["-uitest-wo17"])
        guard openArea("seizures") else { return }
        settle(3)
        if !element("seizures.screen").exists { note("42: seizure diary not on screen") }
        shotToEnd("42-seizures-list")
        scrollUpToTop()
        guard tap(element("seizures.quick.start"), "quick log start") else { return }
        settle(7)
        if !element("seizures.quick.threshold").exists { note("42: plan panel did not appear") }
        shot("42-seizures-running-plan")
        if tap(element("seizures.quick.rescue"), "rescue given") { settle(1) }
        shot("42-seizures-rescue-stamped")
        if tap(element("seizures.quick.stop"), "quick log stop") {
            settle(3)
            shot("42-seizures-recorded")
            if tap(element("seizures.quick.addDetails"), "add details") {
                settle(2)
                shotToEnd("42-seizures-details-sheet")
                dismissSheet()
            }
        }
        scrollUpToTop()
        if let row = probe("seizures.list.row") {
            row.tap()
            settle(3)
            shotToEnd("42-seizures-detail")
            goBack()
        } else {
            note("42: no seizure row")
        }
        scrollUpToTop()
        if tap(element("seizures.toolbar.more"), "diary menu"), tap(element("seizures.toolbar.types"), "types") {
            settle(3)
            shot("42-seizures-types")
            if tap(element("seizures.types.row"), "first type") {
                settle(2)
                shotToEnd("42-seizures-type-sheet")
                dismissSheet()
            }
            goBack()
        }
        if tap(element("seizures.toolbar.more"), "diary menu"), tap(element("seizures.toolbar.rule"), "rule") {
            settle(2)
            shot("42-seizures-rule")
            dismissSheet()
        }
    }

    func test_42_cycleUpcoming() {
        boot(extra: ["-uitest-area-meds", "-uitest-wo17", "-hl.settings.cycleTracking.optIn", "YES"])
        for _ in 0 ..< 6 {
            answerHealthAccess()
            settle(1.5)
        }
        guard openArea("cycle") else { return }
        settle(4)
        answerHealthAccess()
        if probe("cycle.upcoming") == nil { note("42: upcoming cycles not on screen") }
        shot("42-cycle-upcoming")
    }

    func test_42_labsAndVault() {
        boot(extra: ["-uitest-lab-doc", "-uitest-wo17", "-hl.healthkit.serverVersion", "1.48.0"])
        guard openArea("labs") else { return }
        settle(3)
        shotToEnd("42-labs-grouped")
        scrollUpToTop()
        let inr = app.buttons.matching(NSPredicate(format: "identifier == 'labs.byType.item' AND label CONTAINS 'INR'")).firstMatch
        if tap(inr, "INR marker row") {
            settle(3)
            if tap(element("biomarker.detail.gear"), "marker gear") {
                settle(2)
                if probe("biomarker.editor.panelSuggestion") == nil { note("42: panel suggestions not on screen") }
                shot("42-labs-panel-suggestions")
                dismissSheet()
            }
            goBack()
        }
        guard openArea("documents") else { return }
        settle(3)
        if !element("documents.managed.autoRead").exists { note("42: guardian reading switch not on screen") }
        shot("42-documents-guardian")
    }

    func test_42_timelineSeizures() {
        boot(extra: [
            "-uitest-timeline", "-uitest-wo17",
            "-hl.healthkit.serverVersion", "1.48.0",
            "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
            "-hl.healthkit.waistReadRequested.hermetic-user", "true"
        ])
        openDeepLink("healthlog://timeline")
        let inCover = app.buttons["timeline.across.close"].waitForExistence(timeout: 8)
        settle(6)
        shot("42-timeline-seizure-lane")
        // Held across, the bar steps aside after a rest; a touch brings it back.
        let menuIdentifier = inCover ? "timeline.across.choices" : "timeline.choices"
        if inCover { app.revealTimelineControls(waitingFor: menuIdentifier) }
        let menu = app.buttons[menuIdentifier]
        if menu.waitForExistence(timeout: 5) {
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            settle(2)
            shot("42-timeline-choices")
            let symptoms = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Symptom' OR label CONTAINS 'Beschwerden'")).firstMatch
            if symptoms.exists, symptoms.isHittable {
                symptoms.tap()
                settle(1.5)
                shot("42-timeline-symptoms-hidden")
            }
        }
    }
}
