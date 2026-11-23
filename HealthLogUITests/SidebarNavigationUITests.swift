import XCTest

/// The shell's two layouts, one case each, run in whichever window the test
/// is launched in. Compact (iPhone, the Duo's outer display): five tabs and
/// everything else under More. Regular (iPad, the Duo's inner display): the
/// sidebar sections are tabs of their own and More no longer lists them. The
/// branch is taken from the window itself (`AdaptiveShell.isRegular`), and on
/// the pad the regular branch is required, so a case never passes by running
/// the wrong half.
///
/// Navigation goes through `ShellNavigator` only. The deep link case uses
/// `healthlog://check-in` (Mental wellbeing, section Tagebuch) in place of a
/// link on Labor: the custom scheme has no link for the lab list (Preventive
/// care and Cycle arrive only as push paths), and Mental wellbeing is a
/// section the scheme does open, through the same router path.
@MainActor
final class SidebarNavigationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isRegular = false

    private static let labsTitle = "Lab results"
    private static let journalTitle = "Mental wellbeing"
    /// The sidebar section rows in German, which once stood in the top bar.
    private static let germanSectionTitles = [
        "Messwerte", "Beschwerden-Tagebuch", "Zyklus", "Seelisches Wohlbefinden", "Workouts",
        "Laborwerte", "Dokumente", "Vorsorge", "Medizinische Quellen"
    ]
    /// The two section headings, which the old top bar showed as group tabs.
    private static let germanSectionGroups = ["Tagebuch", "Befunde"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = AdaptiveShell.launch()
        isRegular = AdaptiveShell.isRegular(app)
        if AdaptiveShell.deviceIsPad {
            XCTAssertTrue(isRegular, "the pad must offer the sidebar button; the regular branch would not run")
        }
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Choosing a section

    /// A section is chosen where the window keeps it: as a tab of its own when
    /// regular, as a row of More when compact.
    func test_choosingLabsOpensItWhereTheWindowKeepsIt() {
        let name = isRegular ? Self.labsTitle : "more.row.labs"
        XCTAssertTrue(ShellNavigator.select(section: name, in: app), "could not reach the lab list")
        XCTAssertTrue(
            app.navigationBars[Self.labsTitle].waitForExistence(timeout: 15),
            "the lab list did not open"
        )
        assertPlacement(ofOpenedSection: Self.labsTitle)
        if !isRegular { assertBackLeadsToMore() }
    }

    // MARK: - Deep link

    /// A link into a section screen lands in the section tab when regular and
    /// on the More stack, one step above More, when compact.
    func test_deepLinkToASectionLandsWhereTheWindowKeepsIt() {
        AdaptiveShell.open("healthlog://check-in")
        XCTAssertTrue(
            app.navigationBars[Self.journalTitle].waitForExistence(timeout: 15),
            "the link did not open Mental wellbeing"
        )
        assertPlacement(ofOpenedSection: Self.journalTitle)
        if !isRegular { assertBackLeadsToMore(row: "more.row.mental_wellbeing") }
    }

    // MARK: - Turning the device

    /// Turning the device keeps the section. The iPhone is locked to portrait
    /// and the pad stays regular in both orientations, so neither may fall
    /// back to More or lose the screen. The step into a compact window while
    /// the app runs (Stage Manager, folding the Duo) cannot be driven from a
    /// UI test on the simulator; the switch to More is covered by the unit
    /// tests `AppRouterSidebarLayoutTests.sizeClassLossSwitchesToMore` and
    /// `sizeClassLossPushesOntoMoreStack`.
    func test_turningTheDeviceKeepsTheSection() {
        let name = isRegular ? Self.labsTitle : "more.row.labs"
        XCTAssertTrue(ShellNavigator.select(section: name, in: app))
        XCTAssertTrue(app.navigationBars[Self.labsTitle].waitForExistence(timeout: 15))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            waitForWindowToSettle(orientation)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertEqual(
                AdaptiveShell.isRegular(app), isRegular,
                "turning to \(orientation.rawValue) changed the window class"
            )
            XCTAssertTrue(
                app.navigationBars[Self.labsTitle].waitForExistence(timeout: 10),
                "the lab list is gone after turning to \(orientation.rawValue)"
            )
            assertPlacement(ofOpenedSection: Self.labsTitle)
        }
    }

    // MARK: - The two layouts

    /// Compact has no sidebar button and five bar tabs; regular has the button.
    func test_theWindowOffersWhatItsSizeClassPromises() {
        let toggle = AdaptiveShell.sidebarToggle(in: app)
        if isRegular {
            XCTAssertTrue(toggle.exists)
            XCTAssertTrue(ShellNavigator.select(tab: .more, in: app, timeout: 30), "More is missing in the regular shell")
            XCTAssertTrue(
                app.buttons["more.toolbar.gear"].waitForExistence(timeout: 10),
                "the regular shell did not open More"
            )
            XCTAssertFalse(
                app.descendants(matching: .any)["more.row.labs"].exists,
                "More still lists Labs although it is a section tab of its own"
            )
        } else {
            // The bar stands at the bottom on the phone and upright at the
            // edge of the folded Duo; either way it holds the five tabs and
            // nothing more, independent of the sidebar button.
            let barTabs = ShellNavigator.Tab.allCases.filter { tab in
                ShellNavigator.button(tab, in: app).exists || ShellNavigator.toolbarTabButton(tab, in: app).exists
            }
            XCTAssertEqual(barTabs.count, 5, "the compact bar keeps its five tabs")
            if app.tabBars.firstMatch.exists {
                XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5, "the compact bar holds no section tab")
            }
            XCTAssertTrue(ShellNavigator.select(tab: .more, in: app))
            XCTAssertTrue(
                app.descendants(matching: .any)["more.row.labs"].waitForExistence(timeout: 10),
                "compact More must list Labs"
            )
        }
    }

    // MARK: - No top bar

    /// A regular window has no tab bar at the top, only the sidebar (P2,
    /// device test of build 312): with the sidebar folded away, neither a
    /// main tab nor a section stands at the top. More with its settings and
    /// sharing is reached in the sidebar. In a compact window More is a tab
    /// of the bar, at the bottom of the phone or upright on the folded Duo.
    func test_moreIsReachableWhereTheWindowKeepsIt() {
        app.terminate()
        app = AdaptiveShell.launch(language: .de)
        if isRegular {
            if ShellNavigator.sidebarIsOpen(in: app) { AdaptiveShell.sidebarToggle(in: app).tap() }
            assertNoTopBar(picture: "sidebar-de-portrait")
            if AdaptiveShell.deviceIsPad {
                // Turned, the sidebar stands beside the page; folded away,
                // there is still no bar at the top.
                XCUIDevice.shared.orientation = .landscapeLeft
                waitForWindowToSettle(.landscapeLeft)
                if ShellNavigator.sidebarIsOpen(in: app) { AdaptiveShell.sidebarToggle(in: app).tap() }
                assertNoTopBar(picture: "sidebar-de-landscape")
            }
            XCTAssertTrue(ShellNavigator.select(tab: .more, in: app), "Mehr is not in the sidebar")
        } else {
            // The phone's bottom bar, or the folded Duo's upright bar.
            let bottom = ShellNavigator.button(.more, in: app)
            let more = bottom.waitForExistence(timeout: 10) ? bottom : ShellNavigator.toolbarTabButton(.more, in: app)
            XCTAssertTrue(more.waitForExistence(timeout: 5), "Mehr is missing from the tab bar")
            XCTAssertTrue(more.isHittable, "Mehr cannot be tapped in the bar")
            more.tap()
        }
        XCTAssertTrue(app.buttons["more.toolbar.gear"].waitForExistence(timeout: 10), "Mehr did not open")
        XCTAssertTrue(app.buttons["more.toolbar.share"].exists, "Mehr lost its share action")
    }

    // MARK: - The More list beside the sidebar

    /// Turned wide with the sidebar open, the More list stands centred in
    /// the room beside the sidebar, the page margin off its edge, like the
    /// pages of the other tabs. Compact it keeps the page margin.
    func test_moreListStandsBesideTheSidebar() {
        if isRegular {
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForWindowToSettle(.landscapeLeft)
            if !ShellNavigator.sidebarIsOpen(in: app) { AdaptiveShell.sidebarToggle(in: app).tap() }
        }
        XCTAssertTrue(ShellNavigator.select(tab: .more, in: app), "More is not reachable")
        let row = app.descendants(matching: .any)["more.row.about_me"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the More list did not open")
        let window = AdaptiveShell.windowFrame(in: app)
        guard isRegular, let sidebarRow = ShellNavigator.sidebarEntry(.home, in: app) else {
            XCTAssertGreaterThanOrEqual(row.frame.minX, 16, "the list lost its page margin")
            return
        }
        let sidebarEdge = sidebarRow.frame.maxX
        let leading = row.frame.minX - sidebarEdge
        let trailing = window.maxX - row.frame.maxX
        XCTAssertGreaterThanOrEqual(leading, 16, "the list stands against the sidebar (\(leading) pt)")
        XCTAssertEqual(leading, trailing, accuracy: 24, "the list is not centred beside the sidebar")
    }

    // MARK: - Helpers

    /// With the sidebar folded away no tab of a bar stands anywhere: no
    /// main tab, no section, no paging button. The window is photographed
    /// for the record.
    private func assertNoTopBar(picture: String) {
        Thread.sleep(forTimeInterval: 1)
        for tab in [ShellNavigator.Tab.home, .meds, .insights, .more] {
            let button = ShellNavigator.floatingBarButton(tab, in: app)
            XCTAssertFalse(button.exists && button.isHittable, "\(tab) stands in a bar at the top (\(picture))")
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists, "a regular window shows a tab bar (\(picture))")
        let names = Self.germanSectionTitles + Self.germanSectionGroups
            + ["Nächste Seite", "Vorherige Seite"]
        let inBar = app.buttons.matching(NSPredicate(format: "label IN %@", names))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertTrue(inBar.isEmpty, "sections stand in a bar (\(picture)): \(inBar.map(\.label))")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = picture
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Waits until the window stands the way the device was turned, at most
    /// a few seconds. The pad turns its window; the phone is locked to
    /// portrait, so there its window stands upright already.
    private func waitForWindowToSettle(_ orientation: UIDeviceOrientation, timeout: TimeInterval = 5) {
        let window = app.windows.firstMatch
        let wantsLandscape = AdaptiveShell.deviceIsPad && orientation.isLandscape
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = window.frame
            if frame.width > 0, (frame.width > frame.height) == wantsLandscape { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("the window did not turn to \(orientation.rawValue)")
    }

    /// Regular: the opened screen is the root of its own tab, so no back
    /// button. Compact: it was pushed onto More, so there is one.
    private func assertPlacement(ofOpenedSection title: String, file: StaticString = #filePath, line: UInt = #line) {
        let back = AdaptiveShell.backButton(in: app)
        if isRegular {
            XCTAssertFalse(back.exists, "\(title) must be the root of its own tab, not pushed", file: file, line: line)
        } else {
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(title) must be pushed onto More", file: file, line: line)
        }
    }

    /// Compact: the back button leads to the More list, which keeps its row.
    private func assertBackLeadsToMore(
        row: String = "more.row.labs",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let back = AdaptiveShell.backButton(in: app)
        guard back.waitForExistence(timeout: 5) else {
            XCTFail("no back button on a page pushed onto More", file: file, line: line)
            return
        }
        back.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[row].waitForExistence(timeout: 10),
            "the back button did not lead to the More list",
            file: file,
            line: line
        )
    }
}
