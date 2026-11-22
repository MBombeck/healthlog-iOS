import XCTest

/// **The whole-app screenshot sweep.**
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
/// - `HL_SWEEP_LANG` — `de`, `en`, `nl`, `ko`, `es` or `pseudo` (``UITestLanguage``,
///   default `en`).
/// - `HL_SWEEP_XXL` — `1` launches at the accessibility text size AX-XXL.
/// - `HL_SWEEP_XXL_SIZE` — with `HL_SWEEP_XXL=1`, the content size category
///   to launch at instead (for example
///   `UICTContentSizeCategoryAccessibilityXXXL`, the largest).
/// - `HL_SWEEP_DISPLAY` — names the display of the run (``SweepDisplay``): the
///   PNGs land in `HL_SWEEP_OUT/<display>`, a name ending in `-ax5` launches at
///   the largest text size, `portrait` or `landscape` in it sets the device
///   orientation, and a named display is light unless it ends in `-dark`. The explicit variables below still win.
/// - `HL_SWEEP_APPEARANCE` — `light` launches with the app's light
///   appearance (Settings → Aussehen); the default is the app's dark one.
///
/// World: the hermetic marketing boot (`-uitest-marketing`, three medications,
/// four wellness scores) plus the sweep overlay (`-uitest-sweep`, readings for
/// the six metric pages), all network-free and `#if DEBUG`.
@MainActor
final class QASweepScreenshotsTest: XCTestCase {
    nonisolated let env = ProcessInfo.processInfo.environment
    nonisolated var display: SweepDisplay {
        SweepDisplay(environmentValue: env["HL_SWEEP_DISPLAY"])
    }

    nonisolated var outputDir: String {
        display.directory(under: env["HL_SWEEP_OUT"] ?? "")
    }

    /// The light appearance, by explicit variable or by the display's tag.
    var isLightAppearance: Bool {
        if let explicit = env["HL_SWEEP_APPEARANCE"] { return explicit == "light" }
        return display.wantsLight ?? false
    }

    var language: UITestLanguage {
        UITestLanguage(environmentValue: env["HL_SWEEP_LANG"])
    }

    var isXXL: Bool {
        env["HL_SWEEP_XXL"] == "1" || display.isAX5
    }

    /// The content size category of an `isXXL` launch.
    var xxlCategory: String {
        env["HL_SWEEP_XXL_SIZE"]
            ?? (display.isAX5 ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryAccessibilityXXL")
    }

    var app = XCUIApplication()

    /// Where `scrollDown()` drags, as a fraction of the width. The
    /// middle by default; a page whose chart sits under the middle drag (the
    /// chart takes the drag as a scrub) is walked from the right gutter.
    var scrollColumn: CGFloat = 0.5

    /// Set by a case that has nothing to photograph in this configuration
    /// (a largest-text-only case in a default run). Every other case must
    /// write at least one picture, or it fails.
    /// Read in the nonisolated `tearDownWithError`; written only by the case
    /// itself, which has finished by then.
    nonisolated(unsafe) var expectsNoPicture = false
    private nonisolated(unsafe) var originalOrientation: UIDeviceOrientation?
    private nonisolated(unsafe) var startedAt = Date.distantFuture

    override func setUpWithError() throws {
        let missing = (env["HL_SWEEP_OUT"] ?? "").isEmpty
        try XCTSkipIf(missing, "HL_SWEEP_OUT not set — the QA sweep only runs on request")
        continueAfterFailure = true
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir),
            withIntermediateDirectories: true
        )
        // Remember the orientation, so a landscape run does not leave the
        // simulator turned for the next test; a display without a statement is
        // photographed upright.
        originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = display.wantsLandscape == true ? .landscapeLeft : .portrait
        startedAt = Date().addingTimeInterval(-1)
    }

    override func tearDownWithError() throws {
        if let restored = originalOrientation {
            MainActor.assumeIsolated { XCUIDevice.shared.orientation = restored }
        }
        guard !outputDir.isEmpty, !expectsNoPicture else { return }
        XCTAssertGreaterThan(picturesWrittenSinceStart(), 0, "\(name) wrote no picture")
    }

    private nonisolated func picturesWrittenSinceStart() -> Int {
        let directory = URL(fileURLWithPath: outputDir)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard url.pathExtension == "png", let modified = values?.contentModificationDate else { return false }
            return modified >= startedAt
        }.count
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
        guard tapLogTab() else { return false }
        settle(2)
        return true
    }

    // MARK: - Medications

    func test_02_medications() {
        boot()
        tab("pills.fill")
        shotPair("02-meds-list")
        scrollUpToTop()
        // At the largest text size the card sits below the first screen.
        if let card = probe("medications.card.mkshot-med-trulicity") {
            card.tap()
            settle(3)
            shotPair("02-meds-detail")
            scrollUpToTop()
            // The pencil glyph, not the localized label: in nl the walk
            // never found the button by word.
            let pencil = app.navigationBars.buttons.containing(.image, identifier: "pencil").firstMatch
            let edit = pencil.exists ? pencil : app.navigationBars.buttons.matching(
                NSPredicate(format: "label IN %@", ["Edit", "Bearbeiten", "Bewerken"])
            ).firstMatch
            if tap(edit, "Edit button on detail") {
                settle(2)
                shotPair("02-meds-edit")
                dismissSheet()
            }
            goBack()
        } else {
            note("not found: Trulicity card")
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
        boot()
        // Every page carries a chart whose scrub takes a middle drag.
        scrollColumn = 0.97
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
        boot()
        scrollColumn = 0.97 // Past the chart's scrub.
        for slug in ["weight", "blood-pressure", "pulse", "blood-glucose", "sleep", "oxygen"] {
            openDeepLink("healthlog://insights/\(slug)")
            settle(5)
            shotPair("04-metric-\(slug)")
            scrollUpToTop()
        }
    }

    // MARK: - More → every section

    func test_05_moreSections() {
        boot()
        tab("ellipsis")
        shotPair("05-more")
        let rows = [
            "about_me", "measurements", "labs", "documents", "vorsorge", "mental_wellbeing",
            "illness", "cycle", "nutrition", "environment", "allergies", "family_history",
            "personal_records", "achievements", "workouts", "medical_sources"
        ]
        let regular = AdaptiveShell.isRegular(app)
        for row in rows {
            // In a regular window a section is a sidebar tab and no row of
            // More: photograph it there, as a tab root.
            if regular, sectionTitle(forMoreRow: row) != nil {
                sectionTabShot(row)
                continue
            }
            scrollUpToTop()
            guard let target = probe("more.row.\(row)") else {
                note("More row not present: \(row)")
                continue
            }
            target.tap()
            settle(3)
            answerHealthAccess()
            shotPair("05-more-\(row)")
            if row == "workouts" { workoutDetailShot() }
            goBack()
            settle(1)
        }
    }

    // MARK: - Settings

    func test_06_settings() {
        boot()
        guard openSettings() else { return }
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
            answerHealthAccess()
            shotPair("06-settings-\(row)")
            scrollUpToTop()
            if row == "account" { profileWalk() }
            if row == "integrations" { appleHealthWalk() }
            if row == "about" { licensesWalk() }
            goBack()
            settle(1)
        }
    }

    // MARK: - Share (last on purpose: the en Share → Insights path freezes, G1)

    func test_07_share() {
        boot()
        guard openMore(), tap(app.buttons["more.toolbar.share"], "share glyph") else { return }
        waitFor("sharing.unified.produce", 15)
        settle(3)
        shot("07-share-top")
        for step in 1 ... 3 {
            scrollDown()
            shot("07-share-scroll\(step)")
        }
        // The surface opens with no form chosen; the chosen form carries the
        // check mark of a single choice.
        scrollUpToTop()
        guard let pdf = probe("sharing.unified.form.pdf") else {
            note("07: form row pdf not present")
            XCTFail("the output form rows were not reached")
            return
        }
        pdf.tap()
        settle(2)
        shot("07-share-form-chosen")
    }

    // MARK: - Coach, mood

    /// The plain sweep boot declines the AI consent, and without an assistant
    /// the coach link opens nothing: the picture showed the Insights overview.
    /// So this walk boots the way the Coach walk does and takes the same way in.
    func test_08_coachAndMood() {
        bootAcceptingAI(extra: ["-uitest-coach-r", "-uitest-citations"])
        openCoachSheet()
        if !app.textFields.firstMatch.waitForExistence(timeout: 5) {
            note("08-coach: coach sheet not open")
        }
        shot("08-coach")
        dismissSheet()
        openDeepLink("healthlog://check-in")
        settle(3)
        shotPair("08-checkin")
        dismissSheet()
    }

    // MARK: - Cycle (opt-in on via the argument domain)

    func test_09_cycle() {
        boot(extra: ["-hl.settings.cycleTracking.optIn", "YES"])
        answerHealthAccess()
        tab("ellipsis")
        answerHealthAccess()
        guard let row = probe("more.row.cycle") else {
            note("Cycle: More row not present under opt-in")
            return
        }
        row.tap()
        settle(4)
        answerHealthAccess()
        shotPair("09-cycle-home")
        scrollUpToTop()
        if openLogSheet(), tap(element("capture.picker.row.cycle"), "capture row cycle") {
            settle(2)
            shotPair("09-cycle-log-sheet")
            dismissSheet()
        }
    }

    // MARK: - About, scrolled (the small-device hang)

    /// On iPhone SE (de and en) the app froze on Settings → About after
    /// one slow drag: main thread busy, every UI query timed out. This walk
    /// goes straight there, drags twice and asks the app one question; a hang
    /// fails it with XCUITest's own "main thread busy" error.
    func test_10_aboutScroll() {
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        // At the largest text size eight drags stop one row short of About.
        guard let about = deepProbe("settings.hub.about") else {
            note("10-about: settings.hub.about not reached")
            return
        }
        about.tap()
        settle(2)
        shot("10-about-top")
        scrollDown()
        scrollDown()
        shot("10-about-scrolled")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), "About did not answer after scrolling")
    }

    // MARK: - Personal Records

    /// The records screen straight from the More tab, with the sweep's
    /// records overlay (`SweepRecordFixtures`): hero card, time-range
    /// segments, the record grid and the streak rail. Photographed because it
    /// was German throughout in the English UI.
    func test_11_personalRecords() {
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

    /// `marketing: false` boots the plain hermetic world under the sweep
    /// overlay, still with the sweep's appearance and text size.
    func boot(marketing: Bool = true, extra: [String] = []) {
        app = XCUIApplication()
        var arguments = language.launchArguments + ["-uitest-phase8", "insightsAccessibility"]
            + (marketing ? ["-uitest-marketing"] : []) + [
                "-uitest-sweep",
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ]
        if isXXL {
            arguments += ["-UIPreferredContentSizeCategoryName", xxlCategory]
        }
        if isLightAppearance {
            arguments += HermeticAppearance.lightArguments
        }
        if marketing, let avatar = Bundle(for: Self.self).path(forResource: "marketing-avatar", ofType: "png") {
            arguments += ["-uitest-marketing-avatar", avatar]
        }
        app.launchHermeticAndWaitForDashboard(extraArguments: arguments + extra, timeout: 120)
        settle(8)
        dismissOverlays()
        answerHealthAccess()
    }
}

// MARK: - Sections as tabs

extension QASweepScreenshotsTest {
    /// In a regular window a section is a sidebar tab and no row of More:
    /// photograph it there, as a tab root, then go back to More.
    func sectionTabShot(_ row: String) {
        guard let title = sectionTitle(forMoreRow: row) else { return }
        if ShellNavigator.select(section: title, in: app, timeout: 8) {
            settle(3)
            shotPair("05-more-\(row)")
            if row == "workouts" { workoutDetailShot() }
        } else {
            note("section not in the sidebar: \(row)")
        }
        tab("ellipsis")
        settle(1)
    }

    /// The first workout's page, then back to the list.
    func workoutDetailShot() {
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'workouts.row.'")).firstMatch
        guard first.waitForExistence(timeout: 4) else {
            note("05: no workout row")
            return
        }
        first.tap()
        settle(3)
        shotPair("05-more-workouts-detail")
        goBack()
        settle(1)
    }
}
