import XCTest

/// App Store motifs for the iPad and the iPhone Duo: raw frames for
/// `scripts/appstore-screenshots/compose.py --device ipad-13 | duo-outer |
/// duo-inner`. Run on the target device with
/// `TEST_RUNNER_HL_MARKETING_LANG` (de, en, nl) and
/// `TEST_RUNNER_HL_MARKETING_TAG` (for example `ipad13`, `duo-outer`); the
/// frames land in `/tmp/marketing-shots-<lang>-<tag>/` as `1-start.png`,
/// `2-insights.png`, `3-labs.png` and, where the window is regular,
/// `4-sidebar.png`. Navigation goes through `ShellNavigator`. Like the other
/// capture cases these never fail on a missing surface; they log it.
extension MarketingScreenshotsTest {
    /// The four iPad motifs, portrait, 13 inch.
    func test_capture_ipad_motifs() {
        // The 13-inch frames are portrait; a simulator left in landscape by
        // an earlier case would give frames compose.py cannot place.
        XCUIDevice.shared.orientation = .portrait
        captureAdaptiveMotifs(withSidebar: true, requiresPortrait: true)
    }

    /// The Duo's motifs. The window decides: the outer display is compact (three
    /// motifs, the labs list through More), the inner display is regular and
    /// adds the sidebar. Folding the Duo cannot be driven from a test, so run
    /// it once on each posture with its own tag.
    func test_capture_duo_motifs() {
        captureAdaptiveMotifs(withSidebar: nil)
    }

    private func captureAdaptiveMotifs(withSidebar forced: Bool?, requiresPortrait: Bool = false) {
        let app = bootMarketingApp(extraArguments: ["-uitest-citations"])
        if requiresPortrait {
            let window = AdaptiveShell.windowFrame(in: app)
            guard window.height > window.width else {
                XCTFail("the window stands in landscape (\(window.size)); the iPad motifs are portrait")
                return
            }
        }
        let regular = AdaptiveShell.isRegular(app)
        let wantsSidebar = forced ?? regular

        settle(12)
        _ = ShellNavigator.select(tab: .home, in: app)
        settle(3)
        capture(name: "1-start")

        if ShellNavigator.select(tab: .insights, in: app) {
            _ = app.staticTexts["insights.page.header.title.overview"].waitForExistence(timeout: 20)
            settle(5)
            capture(name: "2-insights")
        } else {
            logSkip("Insights tab not reachable")
        }

        let labsTitle = switch Self.adaptiveLanguage {
        case .de: "Laborwerte"
        case .nl: "Labuitslagen"
        default: "Lab results"
        }
        let name = regular ? labsTitle : "more.row.labs"
        guard ShellNavigator.select(section: name, in: app) else {
            logSkip("Labs not reachable")
            return
        }
        settle(3)
        let biomarker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs.byType.item'")).firstMatch
        if biomarker.waitForExistence(timeout: 8), biomarker.isHittable {
            biomarker.tap()
            settle(4)
            capture(name: "3-labs")
            let back = AdaptiveShell.backButton(in: app)
            if back.exists { back.tap() }
            settle(2)
        } else {
            logSkip("No biomarker row: the labs list stands in for the history")
            capture(name: "3-labs")
        }

        guard wantsSidebar else { return }
        if ShellNavigator.sidebarIsOpen(in: app) || ShellNavigator.toggleSidebar(in: app) {
            settle(2)
            capture(name: "4-sidebar")
        } else {
            logSkip("Sidebar could not be opened")
        }
    }

    private static var adaptiveLanguage: UITestLanguage {
        UITestLanguage(environmentValue: ProcessInfo.processInfo.environment["HL_MARKETING_LANG"])
    }
}
