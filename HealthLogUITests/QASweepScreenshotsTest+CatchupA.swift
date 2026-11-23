import XCTest

/// **#191 catch-up A, photographed.**
///
/// - `test_22a_sleepAbroad`: the hypnogram of a night slept in New York
///   (`-uitest-catchup-a`): bedtime, axis and nap in New York time, the
///   quiet "Zeiten in Ortszeit New York" line under the summary.
/// - `test_22a_weightAbroad`: the weight readings, the two newest taken in New
///   York with "Ortszeit New York 07:15" in their detail line.
/// - `test_22a_workoutPerformance`: a run's detail with the watch's figures
///   (the card "Werte der Uhr", one figure left out).
/// - `test_22a_symptomDoseOffset`: the open Bronchitis' symptoms with the
///   distance to the day's dose under each row (`-uitest-symptom`,
///   `-uitest-dose-offset`, the `day.dose-offset` key).
///
/// Navigation is soft like the rest of the sweep. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_22a_sleepAbroad() {
        boot(extra: [CatchupASweep.argument])
        openDeepLink("healthlog://insights/sleep")
        settle(6)
        let row = element("insights.metric.sleep.hypnogram")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            scrollDown()
        }
        guard row.exists else {
            note("22a: hypnogram row not on the sleep page")
            return
        }
        row.tap()
        settle(4)
        if !element("sleep.hypnogram.zone").exists { note("22a: zone line not shown") }
        shot("22a-sleep-abroad")
        scrollDown()
        shot("22a-sleep-abroad-naps")
    }

    func test_22a_weightAbroad() {
        boot(extra: [CatchupASweep.argument])
        guard openArea("measurements") else { return }
        guard let weight = probe("measurements.picker.row.weight") else {
            note("22a: weight row not in the measurements list")
            shot("22a-measurements")
            return
        }
        weight.tap()
        settle(3)
        shot("22a-weight-abroad")
    }

    func test_22a_workoutPerformance() {
        boot(extra: [CatchupASweep.argument])
        guard openArea("workouts") else { return }
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'workouts.row.'")).firstMatch
        guard first.waitForExistence(timeout: 6) else {
            note("22a: no workout row")
            shot("22a-workouts")
            return
        }
        first.tap()
        settle(3)
        let card = element("workout.performance")
        for _ in 0 ..< 6 where !(card.exists && card.isHittable) {
            scrollDown()
        }
        if !card.exists { note("22a: performance card not shown") }
        shot("22a-workout-performance")
    }

    func test_22a_symptomDoseOffset() {
        boot(extra: [
            "-uitest-area-meds", "-uitest-symptom", CatchupASweep.doseOffsetArgument,
            "-hl.healthkit.serverVersion", "1.49.0",
            // The capability the offset line opens on (`/api/version` `features`).
            "-hl.server.featureKeys", "day.dose-offset"
        ])
        guard openArea("illness") else { return }
        guard tap(app.staticTexts["Bronchitis"].firstMatch, "illness episode Bronchitis") else { return }
        settle(3.5)
        let section = element("symptoms.section")
        for _ in 0 ..< 8 where !(section.exists && section.isHittable) {
            scrollDown()
        }
        guard section.exists else {
            note("22a: no symptoms section")
            return
        }
        settle(2)
        // The row reads as one element, so its label carries the offset.
        let offset = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Metformin'")).firstMatch
        if !offset.exists { note("22a: no dose offset line") }
        shot("22a-symptom-doseOffset")
    }
}

private enum CatchupASweep {
    static let argument = "-uitest-catchup-a"
    static let doseOffsetArgument = "-uitest-dose-offset"
}
