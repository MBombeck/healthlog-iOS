import XCTest

/// The regular shell is the sidebar beside its detail, without a bar at the
/// top (P2, device test of build 312). Upright the sidebar is folded away
/// behind the system's button and slides over the page; across it stands
/// beside the page. The sidebar lists Dashboard, Medications, Insights, the
/// timeline at the head of "Tagebuch" and More at the foot. The timeline
/// opens from its row with its board. The "+" of Dashboard opens the capture
/// picker on itself, in German, English and Dutch. Compact windows keep the
/// bottom bar with its five tabs.
@MainActor
final class ShellSidebarUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The timeline's sidebar row in each language.
    private static let timelineTitles: [UITestLanguage: String] = [
        .de: "Zeitleiste", .en: "Timeline", .nl: "Tijdlijn"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func test_sidebarCarriesEveryPlaceAndThePlusOpensCapture() {
        for language in [UITestLanguage.de, .en, .nl] {
            app = AdaptiveShell.launch(language: language)
            guard isRegular() else {
                XCTAssertFalse(AdaptiveShell.deviceIsPad, "the pad must run the regular branch")
                assertCompactBar()
                return
            }
            attach("\(language.rawValue)-start")
            assertNoBarAtTheTop(state: "\(language.rawValue)-start")
            assertCapturePickerOpensFromThePlus(language)
            XCTAssertTrue(ShellNavigator.toggleSidebar(in: app) || ShellNavigator.sidebarIsOpen(in: app), "the sidebar does not open")
            for tab in [ShellNavigator.Tab.home, .meds, .insights, .more] {
                XCTAssertNotNil(ShellNavigator.sidebarEntry(tab, in: app), "\(tab) is not in the sidebar (\(language.rawValue))")
            }
            attach("\(language.rawValue)-sidebar-open")
            if let title = Self.timelineTitles[language] {
                XCTAssertNotNil(
                    ShellNavigator.sidebarRow(titled: [title], in: app),
                    "the timeline has no sidebar row (\(language.rawValue))"
                )
                XCTAssertTrue(ShellNavigator.select(section: title, in: app), "\(title) is not in the sidebar")
                XCTAssertTrue(
                    app.descendants(matching: .any)["timeline.screen"].waitForExistence(timeout: 10),
                    "the timeline did not open from its row (\(language.rawValue))"
                )
                attach("\(language.rawValue)-timeline")
            }
            XCTAssertTrue(ShellNavigator.select(tab: .home, in: app), "Dashboard is not in the sidebar")
            XCTAssertTrue(
                app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 10),
                "Dashboard did not open (\(language.rawValue))"
            )
            XCTAssertTrue(
                ShellNavigator.captureButton(in: app).waitForExistence(timeout: 5),
                "the + is missing back on Dashboard (\(language.rawValue))"
            )
            app.terminate()
        }
    }

    /// Across, every iPad keeps the sidebar beside the page from the start,
    /// and still no bar stands at the top.
    func test_acrossTheSidebarStandsBesideThePage() {
        app = AdaptiveShell.launch(language: .de)
        guard isRegular(), AdaptiveShell.deviceIsPad else {
            XCTAssertFalse(AdaptiveShell.deviceIsPad, "the pad must run the regular branch")
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForOpenSidebar(), "across, the sidebar does not stand beside the page")
        XCTAssertTrue(ShellNavigator.select(section: "Laborwerte", in: app), "Laborwerte is not in the sidebar")
        XCTAssertTrue(app.navigationBars["Laborwerte"].waitForExistence(timeout: 10), "Laborwerte did not open")
        XCTAssertTrue(waitForOpenSidebar(), "choosing a row across folded the sidebar away")
        attach("de-across-Laborwerte")
        assertNoBarAtTheTop(state: "de-across-Laborwerte")
    }

    /// An upright swipe in the middle of the timeline's board scrolls the
    /// page (device test of 312: it only scrolled at the board's edges). A
    /// short press before the swipe is no hold, so it never scrubs. Runs on
    /// every device: the pad's page, the phone's turned full screen.
    func test_theBoardScrollsUprightUnderTheFinger() {
        app = AdaptiveShell.launch(extra: [
            "-uitest-timeline",
            "-hl.healthkit.serverVersion", "1.47.1",
            "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
            "-hl.healthkit.waistReadRequested.hermetic-user", "true",
            // Eight lines: the page is taller than any window, so it can scroll.
            "-timeline.values",
            #"("BLOOD_PRESSURE_SYS","BLOOD_PRESSURE_DIA","WEIGHT","RESTING_HEART_RATE","SLEEP_DURATION","lab:bm_ggt","lab:bm_got","symptom:sd_headache")"#
        ])
        AdaptiveShell.open("healthlog://timeline")
        XCTAssertTrue(
            app.descendants(matching: .any)["timeline.board"].waitForExistence(timeout: 20),
            "the timeline's board did not come up"
        )
        Thread.sleep(forTimeInterval: 2)
        let boards = app.descendants(matching: .any).matching(identifier: "timeline.board").allElementsBoundByIndex
        guard let board = boards.last(where: { $0.exists && $0.isHittable }) ?? boards.last else {
            XCTFail("no board on screen")
            return
        }
        let before = board.frame.minY
        let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)))
        Thread.sleep(forTimeInterval: 1.5)
        attach("timeline-scrolled")
        XCTAssertLessThan(
            board.frame.minY, before - 60,
            "an upright swipe in the middle of the board did not scroll the page (\(before) to \(board.frame.minY))"
        )
    }

    /// Review P2: a press, a hold and a drag along the board picks another
    /// moment; the summary's title follows.
    func test_holdAndDragPicksAnotherMoment() {
        app = AdaptiveShell.launch(extra: Self.timelineWorld)
        AdaptiveShell.open("healthlog://timeline")
        guard let board = frontmost("timeline.board", timeout: 20) else {
            XCTFail("the timeline's board did not come up")
            return
        }
        guard let title = frontmost("timeline.summary.title", timeout: 10) else {
            XCTFail("the summary has no title")
            return
        }
        let before = title.label
        let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.25))
        start.press(forDuration: 0.8, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.25)))
        Thread.sleep(forTimeInterval: 1)
        attach("timeline-scrubbed")
        let after = frontmost("timeline.summary.title", timeout: 5)?.label
        XCTAssertNotEqual(after, before, "holding and dragging did not pick another moment")
    }

    /// Review P2: the detail keeps a visited place as it was left. Insights
    /// on a page other than the overview, then Dashboard, then Insights
    /// again shows the same page.
    func test_insightsKeepsItsPageAcrossDashboard() {
        app = AdaptiveShell.launch()
        XCTAssertTrue(ShellNavigator.select(tab: .insights, in: app), "Insights is not reachable")
        let pager = app.descendants(matching: .any).matching(identifier: "insights.pager").firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 20), "the Insights pager did not come up")
        Thread.sleep(forTimeInterval: 3)
        pager.swipeLeft()
        Thread.sleep(forTimeInterval: 2)
        let page = visibleInsightsPage()
        XCTAssertNotNil(page, "no Insights page on screen")
        XCTAssertNotEqual(page, "insights.page.overview", "the pager did not leave the overview")
        XCTAssertTrue(ShellNavigator.select(tab: .home, in: app), "Dashboard is not reachable")
        XCTAssertTrue(app.staticTexts["dashboard.greeting"].waitForExistence(timeout: 10), "Dashboard did not open")
        XCTAssertTrue(ShellNavigator.select(tab: .insights, in: app), "Insights is not reachable again")
        Thread.sleep(forTimeInterval: 2)
        attach("insights-kept")
        XCTAssertEqual(visibleInsightsPage(), page, "Insights came back on another page")
    }

    // MARK: - Steps

    /// The timeline's hermetic world with eight lines.
    private static let timelineWorld = [
        "-uitest-timeline",
        "-hl.healthkit.serverVersion", "1.47.1",
        "-hl.healthkit.rmssdReadRequested.hermetic-user", "true",
        "-hl.healthkit.waistReadRequested.hermetic-user", "true",
        "-timeline.values",
        #"("BLOOD_PRESSURE_SYS","BLOOD_PRESSURE_DIA","WEIGHT","RESTING_HEART_RATE","SLEEP_DURATION","lab:bm_ggt","lab:bm_got","symptom:sd_headache")"#
    ]

    /// The element with `identifier` that is in front: on the phone the page
    /// stays under the turned full screen, so two of each exist.
    private func frontmost(_ identifier: String, timeout: TimeInterval) -> XCUIElement? {
        guard app.descendants(matching: .any)[identifier].waitForExistence(timeout: timeout) else { return nil }
        Thread.sleep(forTimeInterval: 1)
        let all = app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
        return all.last(where: { $0.exists && $0.isHittable }) ?? all.last
    }

    /// The identifier of the Insights page on screen.
    private func visibleInsightsPage() -> String? {
        let pages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'insights.page.'"))
            .allElementsBoundByIndex
        return pages.first(where: { $0.exists && $0.isHittable })?.identifier
    }

    /// Whether the window is regular. The first launch of a run comes up
    /// slowly under load, so the sidebar button gets longer than the
    /// shared check's three seconds.
    private func isRegular() -> Bool {
        AdaptiveShell.sidebarToggle(in: app).waitForExistence(timeout: 15)
    }

    /// Waits for the sidebar beside the page; turning the window takes a moment.
    private func waitForOpenSidebar(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ShellNavigator.sidebarIsOpen(in: app) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// No tab of a bar stands anywhere: the main places are rows of the
    /// sidebar only.
    private func assertNoBarAtTheTop(state: String) {
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a regular window shows a tab bar (\(state))")
        for tab in [ShellNavigator.Tab.home, .meds, .insights] {
            let button = ShellNavigator.floatingBarButton(tab, in: app)
            XCTAssertFalse(button.exists && button.isHittable, "\(tab) stands in a bar at the top (\(state))")
        }
    }

    /// The "+" of Dashboard opens the capture picker as a popover on it.
    private func assertCapturePickerOpensFromThePlus(_ language: UITestLanguage) {
        let plus = ShellNavigator.captureButton(in: app)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "Dashboard has no + (\(language.rawValue))")
        guard plus.exists, plus.isHittable else { return }
        // Read before the tap: the open popover takes the bar out of the tree.
        let plusFrame = plus.frame
        plus.tap()
        let row = app.descendants(matching: .any)["capture.picker.row.measurement"]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the + did not open the capture picker (\(language.rawValue))")
        attach("\(language.rawValue)-capture")
        if row.exists {
            // On the "+" at the trailing edge, not at the top centre.
            let window = AdaptiveShell.windowFrame(in: app)
            XCTAssertLessThan(
                abs(row.frame.midX - plusFrame.midX), abs(row.frame.midX - window.midX),
                "the picker does not hang on the + (\(language.rawValue))"
            )
        }
        // Tapping beside a popover closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        _ = row.waitForNonExistence(timeout: 5)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "shell-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Compact: Labs opens on More, and the bottom bar keeps five tabs.
    private func assertCompactBar() {
        XCTAssertTrue(ShellNavigator.select(section: "more.row.labs", in: app), "could not reach Labs")
        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5, "the compact bar holds no section tab")
        }
    }
}
