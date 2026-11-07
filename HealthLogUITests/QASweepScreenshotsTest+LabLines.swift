import XCTest

/// 1.5 LAB-LINES — the metric chart against a 1.47 server with the timeline
/// module on (`-uitest-lab-lines`, `LabLinesFixtures`): the weight page with
/// the usual-range line (latest reading two days ago) and HbA1c under the
/// chart (remembered choice via the argument domain), the opened
/// "Erweitert" with both choices, the blood pressure chart narrowed to the
/// morning. Without the argument (the sweep's 1.43 server, module map
/// without `timeline`) none of it appears: the "before" picture. Runs with
/// the sweep's language, appearance and text size. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19l_labLines() {
        // `-uitest-bp-tod` too, so the blood pressure page's "Nach Tageszeit"
        // section has its own answers in the picture.
        boot(extra: [
            "-uitest-lab-lines",
            "-uitest-bp-tod",
            "-hl.healthkit.serverVersion", "1.47.0",
            "-insights.labOverlay.weight", "lab:bm_hba1c"
        ])
        openDeepLink("healthlog://insights/weight")
        settle(6)
        scrollColumn = 0.96
        if probe("chart.card.headline") == nil { note("19l: usual-range line not on screen") }
        shot("19l-weight-chart")
        if probe("insights.labOverlay.chart") == nil { note("19l: lab marker not on screen") }
        scrollDown()
        shot("19l-weight-lab")
        if let advanced = hittableAdvanced() {
            advanced.tap()
            settle(3)
            scrollDown()
            shot("19l-weight-advanced")
        } else {
            note("19l: Advanced link not on screen (weight)")
        }

        scrollUpToTop()
        openDeepLink("healthlog://insights/blood-pressure")
        settle(6)
        // The pager keeps the weight page alive beside this one, with its own
        // link of the same name: take the one on screen.
        if let advanced = hittableAdvanced() {
            advanced.tap()
            settle(2)
            pickMenuItem(opening: ["Ganzer Tag", "Whole day"], choose: ["Morgens", "Morning"])
            settle(4)
            scrollUpToTop()
            if probe("chart.card.caption") == nil { note("19l: part-of-day caption not on screen") }
            shot("19l-bp-morning")
        } else {
            note("19l: Advanced link not on screen (blood pressure)")
        }
        scrollColumn = 0.5
    }

    /// The same weight page against the sweep's own server: no line, no
    /// marker, no "Erweitert" (the "before" picture and Regel 10).
    func test_19l_labLinesBefore() {
        guard !isXXL else { return }
        boot(extra: ["-insights.labOverlay.weight", "lab:bm_hba1c"])
        openDeepLink("healthlog://insights/weight")
        settle(6)
        scrollColumn = 0.96
        shotPair("19l-weight-before")
        scrollDown()
        shot("19l-weight-before-scroll2")
        scrollColumn = 0.5
    }

    /// The "Erweitert" link of the page on screen, scrolling at most eight times.
    private func hittableAdvanced() -> XCUIElement? {
        for _ in 0 ..< 9 {
            let matches = app.descendants(matching: .any).matching(identifier: "insights.metric.advanced")
            for index in 0 ..< matches.count {
                let candidate = matches.element(boundBy: index)
                if candidate.exists, candidate.isHittable { return candidate }
            }
            scrollDown()
        }
        return nil
    }

    /// Opens the first hittable menu button labelled like `opening`, then
    /// taps the item labelled like `choose`.
    private func pickMenuItem(opening: [String], choose: [String]) {
        var opened = false
        for label in opening where !opened {
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", label, label)).firstMatch
            if button.exists, button.isHittable {
                button.tap()
                opened = true
            }
        }
        guard opened else {
            note("19l: part-of-day menu not hittable")
            return
        }
        settle(1.5)
        for label in choose {
            let item = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if item.exists, item.isHittable {
                item.tap()
                return
            }
        }
        note("19l: menu item not found: \(choose)")
    }
}
