import UIKit
import XCTest

/// What the adaptive-shell UI tests need to know about the window they run in.
///
/// The shell decides on the size class of its window: compact shows the five
/// tabs in a bar and everything else under More, regular shows the sidebar
/// sections as tabs of their own. A UI test cannot read the size class, but it
/// can see its effect: only a regular window carries the system button that
/// opens and closes the sidebar ("Seitenleiste ein-/ausblenden", identifier
/// `ToggleSideBar`). Every case asks `isRegular` and checks the expectations of
/// the window it is in. Nothing here is skipped: the same case runs on the
/// iPhone (compact branch) and on the iPad or the Duo's inner display (regular
/// branch).
@MainActor
enum AdaptiveShell {
    /// Launch arguments of the shared hermetic world with lab values, a dense
    /// blood pressure series and the Health banner suppressed. The interface
    /// is English, so titles can be matched by their text.
    static let launchExtras = [
        "-uitest-citations",
        "-uitest-phase8", "insightsAccessibility",
        "-hl.healthkit.requestedAt.hermetic-user", "true",
        "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
    ]

    /// Launches the hermetic shell, in English unless `language` says
    /// otherwise, and waits for the dashboard.
    static func launch(
        extra: [String] = [],
        language: UITestLanguage = .en,
        timeout: TimeInterval = 90
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += language.launchArguments
        app.launchHermeticAndWaitForDashboard(extraArguments: launchExtras + extra, timeout: timeout)
        declineAssistantConsent(in: app)
        return app
    }

    /// The hermetic world has an AI provider, so the assistant consent sheet
    /// comes up over the dashboard a moment after launch and covers the shell.
    /// Declining closes it without a server call, as the capture runs do.
    static func declineAssistantConsent(in app: XCUIApplication) {
        let decline = app.buttons.matching(NSPredicate(format: "label IN %@", ["Decline", "Ablehnen", "Weigeren"])).firstMatch
        if decline.waitForExistence(timeout: 6) {
            if decline.isHittable { decline.tap() }
            _ = decline.waitForNonExistence(timeout: 5)
        }
    }

    /// The system's sidebar button, in any of the app languages.
    static func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == 'ToggleSideBar' OR label CONTAINS[c] 'sidebar' OR label CONTAINS[c] 'seitenleiste' OR label CONTAINS[c] 'zijbalk' OR label CONTAINS[c] 'navigatiekolom'"
        )).firstMatch
    }

    /// Whether the window is regular: the shell offers the sidebar.
    static func isRegular(_ app: XCUIApplication) -> Bool {
        sidebarToggle(in: app).waitForExistence(timeout: 3)
    }

    /// The pad is regular in every window the tests run it in. This is the
    /// cross-check that keeps `isRegular` honest: a pad without the button
    /// would otherwise run the compact branch and pass for the wrong reason.
    static var deviceIsPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// The back button of the navigation bar on top: present on a page pushed
    /// onto a stack, absent on the root of a tab. The pad's top tab bar lives
    /// in the navigation bar too; its More button carries the symbol as its
    /// identifier, so only an unnamed button titled More counts as a back button.
    static func backButton(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(
            format: "identifier == 'BackButton' OR (identifier == '' AND label IN %@)", ShellNavigator.Tab.more.titles
        )).firstMatch
    }

    /// Opens a tab and waits for `arrived`. The bar button is tapped a few
    /// times; the pad's floating top bar can swallow a tap while it settles.
    /// If the bar does not take the tap, the tab is chosen in the sidebar and
    /// the step is recorded in the test's activity log, so a bar that stops
    /// taking taps shows up in the result instead of passing unseen.
    /// `SidebarNavigationUITests.test_moreIsReachableWhereTheWindowKeepsIt` checks the
    /// bar itself.
    @discardableResult
    static func open(
        _ tab: ShellNavigator.Tab,
        in app: XCUIApplication,
        button: XCUIElement,
        until arrived: XCUIElement,
        attempts: Int = 3
    ) -> Bool {
        for _ in 0 ..< attempts {
            if button.exists, button.isHittable {
                button.tap()
            } else if let bar = ShellNavigator.hittableTabButton(tab, in: app) {
                // The given button resolved to an unreachable copy of the tab.
                bar.tap()
            }
            if arrived.waitForExistence(timeout: 4) { return true }
        }
        XCTContext.runActivity(named: "The bar did not open \(tab); falling back to the sidebar") { activity in
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "bar-fallback-\(tab)"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        if ShellNavigator.toggleSidebar(in: app) || ShellNavigator.sidebarIsOpen(in: app),
           let row = ShellNavigator.sidebarEntry(tab, in: app)
        {
            row.tap()
        }
        return arrived.waitForExistence(timeout: 8)
    }

    /// The window's frame in points.
    static func windowFrame(in app: XCUIApplication) -> CGRect {
        app.windows.firstMatch.frame
    }

    /// Attaches the element tree, so a failure reads without a rerun.
    static func attachTree(of app: XCUIApplication, named name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// Opens a healthlog:// link the way a notification or another app does.
    static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        XCUIDevice.shared.system.open(url)
    }
}
