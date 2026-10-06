import XCTest

/// **H2 (1.1.0) — the whole-app screenshot sweep.**
///
/// Screenshots found two defects no test did (an untranslated "66% today" and
/// the English Share → Insights freeze), so before a release every main screen
/// is photographed in both languages, on a large and a small device, and read
/// by eye. This class is that camera. It is **not** a gate: navigation is soft
/// (a missing element writes a line to `_notes.txt` and the walk moves on), and
/// the whole class skips unless `TEST_RUNNER_HL_SWEEP_OUT` names an output
/// directory, so a plain suite run never pays for it.
///
/// Environment (forwarded by xcodebuild with the `TEST_RUNNER_` prefix):
/// - `HL_SWEEP_OUT` — absolute host directory the PNGs land in (the simulator
///   shares the host filesystem, the same seam `MarketingScreenshotsTest` uses).
/// - `HL_SWEEP_LANG` — `de` or `en` (default `en`).
/// - `HL_SWEEP_XXL` — `1` launches at the accessibility text size AX-XXL.
///
/// World: the hermetic marketing boot (`-uitest-marketing`, three medications,
/// four wellness scores) plus the sweep overlay (`-uitest-sweep`, readings for
/// the six metric pages), all network-free and `#if DEBUG`.
@MainActor
final class QASweepScreenshotsTest: XCTestCase {
    nonisolated let env = ProcessInfo.processInfo.environment
    nonisolated var outputDir: String {
        env["HL_SWEEP_OUT"] ?? ""
    }

    var language: String {
        env["HL_SWEEP_LANG"] ?? "en"
    }

    var isXXL: Bool {
        env["HL_SWEEP_XXL"] == "1"
    }

    var app = XCUIApplication()

    override func setUpWithError() throws {
        let missing = outputDir.isEmpty
        try XCTSkipIf(missing, "HL_SWEEP_OUT not set — the QA sweep only runs on request")
        continueAfterFailure = true
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir),
            withIntermediateDirectories: true
        )
    }

    // MARK: - The five main screens (also the Dynamic-Type pass)

    func test_00_mainTabs() {
        boot()
        shotPair("00-home")
        tab("pills.fill")
        shotPair("00-meds")
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        shotPair("00-insights")
        tab("ellipsis")
        shotPair("00-more")
        scrollUpToTop()
        if tap(app.buttons["more.toolbar.gear"], "settings gear") {
            settle(2)
            shotPair("00-settings")
        }
    }

    // MARK: - Dashboard + Log

    func test_01_dashboardAndLog() {
        guard !isXXL else { return }
        boot()
        shot("01-dashboard-top")
        scrollDown()
        shot("01-dashboard-scroll1")
        scrollDown()
        shot("01-dashboard-scroll2")
        // The Log tab is an action: it raises the capture sheet.
        if openLogSheet() {
            shotPair("01-log-sheet")
            dismissSheet()
        }
        for (row, name) in [("measurement", "01-measure-sheet"), ("medication", "01-intake-sheet"), ("mood", "01-mood-sheet")] {
            guard openLogSheet(), tap(element("capture.picker.row.\(row)"), "capture row \(row)") else { continue }
            settle(2.5)
            shotPair(name)
            dismissSheet()
            dismissSheet()
        }
    }

    /// The Log tab is an action: it raises the capture picker.
    private func openLogSheet() -> Bool {
        let log = app.tabBars.buttons.containing(.image, identifier: "plus.circle.fill").firstMatch
        guard tap(log, "Log tab") else { return false }
        settle(2)
        return true
    }

    // MARK: - Medications

    func test_02_medications() {
        guard !isXXL else { return }
        boot()
        tab("pills.fill")
        shotPair("02-meds-list")
        scrollUpToTop()
        if tap(element("medications.card.mkshot-med-trulicity"), "Trulicity card") {
            settle(3)
            shotPair("02-meds-detail")
            scrollUpToTop()
            let edit = app.navigationBars.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Edit", "Bearbeiten")
            ).firstMatch
            if tap(edit, "Edit button on detail") {
                settle(2)
                shotPair("02-meds-edit")
                dismissSheet()
            }
            goBack()
        }
        scrollUpToTop()
        if tap(element("medications.header.addButton"), "add medication") {
            settle(2)
            shotPair("02-meds-add")
            dismissSheet()
        }
    }

    // MARK: - Insights pager

    func test_03_insightsPages() {
        guard !isXXL else { return }
        boot()
        tab("sparkles")
        waitFor("insights.page.header.title.overview", 20)
        settle(3)
        shotPair("03-insights-overview")
        scrollUpToTop()
        var seen: [String] = []
        for index in 1 ... 24 {
            app.swipeLeft()
            settle(2.5)
            guard let page = visibleInsightsPage() else {
                note("insights pager: no visible page after swipe \(index)")
                break
            }
            if seen.contains(page) { break }
            seen.append(page)
            let slug = page.replacingOccurrences(of: "insights.page.", with: "")
            shotPair(String(format: "03-insights-%02d-%@", index, slug))
            scrollUpToTop()
        }
        note("insights pages seen: \(seen.joined(separator: ", "))")
    }

    // MARK: - Metric detail pages (deep links)

    func test_04_metricPages() {
        guard !isXXL else { return }
        boot()
        for slug in ["weight", "blood-pressure", "pulse", "blood-glucose", "sleep", "oxygen"] {
            openDeepLink("healthlog://insights/\(slug)")
            settle(5)
            shotPair("04-metric-\(slug)")
            scrollUpToTop()
        }
    }

    // MARK: - More → every section

    func test_05_moreSections() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        shotPair("05-more")
        let rows = [
            "about_me", "measurements", "labs", "documents", "vorsorge", "mental_wellbeing",
            "illness", "nutrition", "environment", "allergies", "family_history",
            "personal_records", "achievements", "workouts", "medical_sources"
        ]
        for row in rows {
            scrollUpToTop()
            guard let target = probe("more.row.\(row)") else {
                note("More row not present: \(row)")
                continue
            }
            target.tap()
            settle(3)
            shotPair("05-more-\(row)")
            goBack()
            settle(1)
        }
    }

    // MARK: - Settings

    func test_06_settings() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        shotPair("06-settings-hub")
        let hub = [
            "account", "notifications", "dashboard", "integrations", "devices", "siri", "mcp",
            "apiTokens", "sources", "ai", "serverSync", "export", "healthScore", "modules", "advanced", "about"
        ]
        for row in hub {
            scrollUpToTop()
            guard let target = probe("settings.hub.\(row)") else {
                note("Settings hub row not present: \(row)")
                continue
            }
            target.tap()
            settle(2.5)
            shotPair("06-settings-\(row)")
            scrollUpToTop()
            if row == "account" { profileWalk() }
            if row == "integrations" { appleHealthWalk() }
            goBack()
            settle(1)
        }
    }

    private func profileWalk() {
        guard let profile = probe("settings.account.profileRow") else {
            note("Account: profile row missing")
            return
        }
        profile.tap()
        settle(3)
        shot("06-profile-top")
        // Units sit at the end of the form — walk down to them.
        for step in 1 ... 5 {
            scrollDown()
            shot("06-profile-scroll\(step)")
        }
        goBack()
        settle(1)
    }

    private func appleHealthWalk() {
        guard let appleHealth = probe("settings.integrations.appleHealthRow") else {
            note("Integrations: Apple Health row missing")
            return
        }
        appleHealth.tap()
        settle(3)
        shotPair("06-applehealth")
        scrollUpToTop()
        if let diag = probe("settings.integrations.hkDiagnosticsRow") {
            diag.tap()
            settle(3)
            shotPair("06-sync-diagnostics")
            for step in 2 ... 4 {
                scrollDown()
                shot("06-sync-diagnostics-scroll\(step)")
            }
            if let list = probe("settings.hkdiag.skippedList") {
                list.tap()
                settle(2)
                shotPair("06-sync-diagnostics-rejected")
                goBack()
            } else {
                note("Sync diagnostics: no rejection list (register empty)")
            }
            goBack()
        } else {
            note("Apple Health: diagnostics row missing")
        }
        goBack()
        settle(1)
    }

    // MARK: - Share (last on purpose: the en Share → Insights path freezes, G1)

    func test_07_share() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.share"], "share glyph") else { return }
        waitFor("sharing.unified.produce", 15)
        settle(3)
        shot("07-share-top")
        for step in 1 ... 3 {
            scrollDown()
            shot("07-share-scroll\(step)")
        }
    }

    // MARK: - Coach, mood

    func test_08_coachAndMood() {
        guard !isXXL else { return }
        boot()
        openDeepLink("healthlog://coach")
        settle(4)
        shot("08-coach")
        dismissSheet()
        openDeepLink("healthlog://check-in")
        settle(3)
        shotPair("08-checkin")
        dismissSheet()
    }

    // MARK: - Cycle (opt-in on via the argument domain)

    func test_09_cycle() {
        guard !isXXL else { return }
        boot(extra: ["-hl.settings.cycleTracking.optIn", "YES"])
        dismissHealthAuthorization()
        tab("ellipsis")
        dismissHealthAuthorization()
        guard let row = probe("more.row.cycle") else {
            note("Cycle: More row not present under opt-in")
            return
        }
        row.tap()
        settle(4)
        dismissHealthAuthorization()
        shotPair("09-cycle-home")
        scrollUpToTop()
        if openLogSheet(), tap(element("capture.picker.row.cycle"), "capture row cycle") {
            settle(2)
            shotPair("09-cycle-log-sheet")
            dismissSheet()
        }
    }

    // MARK: - About, scrolled (the small-device hang)

    /// H2 — on iPhone SE (de and en) the app froze on Settings → About after
    /// one slow drag: main thread busy, every UI query timed out. This walk
    /// goes straight there, drags twice and asks the app one question; a hang
    /// fails it with XCUITest's own "main thread busy" error.
    func test_10_aboutScroll() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        guard let about = probe("settings.hub.about") else { return }
        about.tap()
        settle(2)
        shot("10-about-top")
        scrollDown()
        scrollDown()
        shot("10-about-scrolled")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "About did not answer after scrolling")
    }

    // MARK: - Personal Records (L1)

    /// L1 — the records screen straight from the More tab, with the sweep's
    /// records overlay (`SweepRecordFixtures`): hero card, time-range
    /// segments, the record grid and the streak rail. Photographed because it
    /// was German throughout in the English UI.
    func test_11_personalRecords() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        guard let row = probe("more.row.personal_records") else {
            note("More row not present: personal_records")
            return
        }
        row.tap()
        settle(4)
        shot("11-records-top")
        // The widest range shows every record card, not only this week's.
        let picker = app.segmentedControls.firstMatch
        if picker.waitForExistence(timeout: 8) {
            // Right-most segment; its button reports not hittable, the control does.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.875, dy: 0.5)).tap()
            settle(2)
            shot("11-records-alltime")
        } else {
            note("records time-range picker not found")
        }
        scrollDown()
        shot("11-records-scroll1")
        scrollDown()
        shot("11-records-scroll2")
    }

    // MARK: - Boot

    func boot(extra: [String] = []) {
        app = XCUIApplication()
        var arguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "de" ? "de_DE" : "en_US",
            "-uitest-phase8", "insightsAccessibility",
            "-uitest-marketing",
            "-uitest-sweep",
            "-hl.healthkit.requestedAt.hermetic-user", "true",
            "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
        ]
        if isXXL {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        }
        if let avatar = Bundle(for: Self.self).path(forResource: "marketing-avatar", ofType: "png") {
            arguments += ["-uitest-marketing-avatar", avatar]
        }
        app.launchHermeticAndWaitForDashboard(extraArguments: arguments + extra, timeout: 120)
        settle(8)
        dismissOverlays()
    }
}
