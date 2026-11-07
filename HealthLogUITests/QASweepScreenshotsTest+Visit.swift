import XCTest

/// 1.5 VISIT — "Nächster Termin" on Vorsorge (`-uitest-visit`,
/// `VisitFixtures`): the booked visit, where its window starts, what stood out
/// since, and the doctor report link, which opens the sharing surface with the
/// window preset. `test_19v_nextVisitOlderServer` shows the same visit from a
/// server without `preparation`, `test_19v_noVisit` the page without a visit
/// (the "before" picture). Runs with the sweep's language, appearance and text
/// size. Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_19v_nextVisit() {
        boot(extra: ["-uitest-visit"])
        guard openVorsorge() else { return }
        if probe("visit.next") == nil { note("19v: next visit section not on screen") }
        shot("19v-vorsorge-visit")
        scrollDown()
        shot("19v-vorsorge-visit-scrolled")
        guard let link = probe("visit.next.report") else {
            note("19v: report link not present")
            return
        }
        link.tap()
        settle(4)
        if probe("sharing.unified.period.window") == nil { note("19v: preset window not on the sharing screen") }
        shot("19v-sharing-window")
        scrollDown()
        shot("19v-sharing-window-scrolled")
    }

    func test_19v_nextVisitOlderServer() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-visit", "-uitest-visit-plain"])
        guard openVorsorge() else { return }
        shot("19v-vorsorge-visit-olderServer")
    }

    /// POLISH-A A8 — a v1.47.1 server capped the window at two years: the card
    /// says so instead of "since your last visit".
    func test_19v_nextVisitCapped() {
        boot(extra: ["-uitest-visit", "-uitest-visit-capped"])
        guard openVorsorge() else { return }
        if probe("visit.next") == nil { note("19v: next visit section not on screen") }
        shot("19v-vorsorge-visit-capped")
    }

    func test_19v_noVisit() {
        guard !isXXL else { return }
        boot()
        guard openVorsorge() else { return }
        if probe("visit.next") != nil { note("19v: section shown without a booked visit") }
        shot("19v-vorsorge-none")
    }

    /// More, then the Vorsorge row.
    private func openVorsorge() -> Bool {
        tab("ellipsis")
        guard let row = probe("more.row.vorsorge") else {
            note("19v: Vorsorge row not present")
            return false
        }
        row.tap()
        settle(5)
        scrollUpToTop()
        return true
    }
}
