import XCTest

/// The regular shell as the person meets it: the start, the sidebar open
/// and folded away, Dashboard scrolled once, Labs and the timeline chosen in
/// the sidebar, and the capture picker opened from the "+" of Dashboard (the
/// Log tab on the phone). The timeline runs in its own world against a
/// 1.47.1 server with the module on. Runs with the sweep's language and
/// display; on the phone and the folded Duo it photographs the tab bar.
extension QASweepScreenshotsTest {
    func test_41_shellSidebar() {
        boot()
        shot("41-start")
        if ShellNavigator.sidebarIsOpen(in: app) {
            shot("41-sidebar-open")
            AdaptiveShell.sidebarToggle(in: app).tap()
            settle(1)
            shot("41-sidebar-closed")
        } else if ShellNavigator.toggleSidebar(in: app) {
            settle(1)
            shot("41-sidebar-open")
            AdaptiveShell.sidebarToggle(in: app).tap()
            settle(1)
            shot("41-sidebar-closed")
        }
        scrollDown()
        shot("41-dashboard-scroll1")
        let labs = AdaptiveShell.isRegular(app) ? sectionTitle(forMoreRow: "labs") : "more.row.labs"
        if let labs, ShellNavigator.select(section: labs, in: app, timeout: 8) {
            settle(2)
            shot("41-labs")
        } else {
            note("41: Labs not reachable")
        }
        tab("house.fill")
        settle(2)
        if tapLogTab() {
            settle(2)
            shot("41-capture")
        }
        photographTimelineFromTheSidebar()
    }

    /// The timeline opened from its sidebar row (on the phone from More).
    private func photographTimelineFromTheSidebar() {
        app.terminate()
        boot(extra: [
            "-uitest-timeline",
            "-hl.healthkit.serverVersion", "1.47.1",
            "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
            "-hl.healthkit.waistReadRequested.hermetic-user", "true"
        ])
        let titles: [UITestLanguage: String] = [.en: "Timeline", .de: "Zeitleiste", .nl: "Tijdlijn"]
        if AdaptiveShell.isRegular(app) {
            guard ShellNavigator.select(section: titles[language] ?? "Timeline", in: app, timeout: 8) else {
                note("41: timeline not in the sidebar")
                return
            }
        } else {
            // Compact: the row sits low in More; the link opens the same page.
            openDeepLink("healthlog://timeline")
        }
        settle(8)
        if !app.descendants(matching: .any)["timeline.screen"].exists { note("41: timeline screen not on screen") }
        shot("41-timeline")
    }
}
