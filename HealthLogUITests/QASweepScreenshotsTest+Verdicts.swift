import XCTest

/// 1.5 VERDICTS — the trend arrows and their colours against a server that
/// judges every trend itself (`-uitest-verdicts`, `VerdictFixtures`): Today,
/// the Insights overview, the weight, blood pressure, pulse and glucose pages
/// and the mood page (`-uitest-area-meds` brings the mood entries). Runs with
/// the sweep's language and appearance. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19v_verdicts() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-verdicts", "-uitest-area-meds"])
        shotToEnd("19v-today")

        scrollUpToTop()
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        settle(3)
        shotToEnd("19v-insights-overview")
        scrollUpToTop()

        for slug in ["weight", "blood-pressure", "pulse", "blood-glucose"] {
            openDeepLink("healthlog://insights/\(slug)")
            settle(5)
            shotPair("19v-metric-\(slug)")
            scrollUpToTop()
        }

        openDeepLink("healthlog://insights/mood")
        settle(6)
        scrollUpToTop()
        scrollColumn = 0.98
        shot("19v-mood-top")
        scrollColumn = 0.5
    }
}
