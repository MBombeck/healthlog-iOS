import XCTest

/// 1.5 BP-TOD — "Nach Tageszeit" on the blood pressure page against a 1.47
/// server (`-uitest-bp-tod`, `BloodPressureTimeOfDayFixtures`): 30 days with a
/// difference, a week with parts below the floor, six months with a zero
/// difference, one day without readings. Without the argument (the sweep's
/// 1.43 server) the section is absent, which is the "before" picture. Runs
/// with the sweep's language, appearance and text size. Only runs when
/// `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19t_bpTimeOfDay() {
        // The version the foreground probe would record (`KnownServerVersion`),
        // set through the argument domain: the walk does not wait for the probe.
        boot(extra: ["-uitest-bp-tod", "-hl.healthkit.serverVersion", "1.47.0"])
        openDeepLink("healthlog://insights/blood-pressure")
        settle(6)
        scrollColumn = 0.96
        showTimeOfDay("19t-bp-month")
        // Segments of the floating range control, by their spoken label.
        for (labels, slug) in [(["Woche", "Week"], "week"), (["6 Monate", "6 months"], "sixMonths"), (["Tag", "Day"], "day")] {
            pickRange(labels)
            showTimeOfDay("19t-bp-\(slug)")
        }
        scrollColumn = 0.5
    }

    /// The same page against a 1.46 server: no section (the
    /// "before" picture and the older-server case of Regel 10).
    func test_19t_bpTimeOfDayOlderServer() {
        guard !isXXL else { return }
        boot(extra: ["-hl.healthkit.serverVersion", "1.46.6"])
        openDeepLink("healthlog://insights/blood-pressure")
        settle(6)
        scrollColumn = 0.96
        showTimeOfDay("19t-bp-olderServer")
        scrollColumn = 0.5
    }

    /// Scrolls the section into view and photographs it.
    private func showTimeOfDay(_ name: String) {
        scrollUpToTop()
        if probe("insights.bpTimeOfDay") == nil {
            note("\(name): time-of-day section not on screen")
        }
        // One more drag so the whole card, not only its heading, is in frame.
        scrollDown()
        shot(name)
    }

    /// Taps the first hittable segment carrying one of `labels`; the pager
    /// keeps neighbouring pages (and their controls) alive off screen.
    private func pickRange(_ labels: [String]) {
        for label in labels {
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
            for index in 0 ..< matches.count {
                let button = matches.element(boundBy: index)
                if button.exists, button.isHittable {
                    button.tap()
                    settle(4)
                    return
                }
            }
        }
        note("range segment not hittable: \(labels)")
    }
}
