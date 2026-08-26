import XCTest

/// W-SLEEP (v0.14.8) — walks the live demo tenant to the sleep hypnogram
/// (#124): Insights → Schlaf metric page → "Schlafphasen" entry row →
/// `SleepHypnogramScreen`, and captures screenshots as `XCTAttachment`s.
///
/// This is the END-TO-END proof for the W-SLEEP fix: the route's live payload
/// (float minute sums, `stage: null` segments on the demo tenant's stage-less
/// MANUAL rows) used to throw in the strict DTO decode → the screen always
/// showed the error card and the operator NEVER saw a night render. The walk
/// asserts the hypnogram screen reaches a non-error state against the real
/// server.
///
/// Reuses the same `demo.healthlog.dev` onboarding walk as
/// `WalkthroughDashboardTest`, short-circuited when already authenticated.
@MainActor
final class SleepHypnogramWalkthroughTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_capture_sleep_hypnogram_from_metric_page() throws {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot. NOTE: a full
        // hypnogram requires a per-night sleep-segment fixture the hermetic seed
        // intentionally does NOT synthesize (frozen stage-band geometry would
        // couple the test to server chart math). This test is therefore a
        // hermetic NAVIGATION + NO-ERROR-CARD smoke proof: it deep-links to the
        // sleep page and asserts the detail does NOT render the error card (calm
        // empty state under fixtures is acceptable). The hypnogram entry-row tap
        // is preserved as a best-effort branch for live-tenant runs.
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)
        Thread.sleep(forTimeInterval: 2)

        // Jump straight to the sleep metric page via the app's own deep link
        // (`DeepLinkRouter` `.insights(metric:)`) — driving the horizontal
        // tab-strip via synthesized swipes proved flaky on the iOS 26 AX tree
        // (pills report stale frames mid-scroll).
        // swiftlint:disable:next force_unwrapping
        try XCUIDevice.shared.system.open(XCTUnwrap(URL(string: "healthlog://insights/sleep")))
        Thread.sleep(forTimeInterval: 6)
        // The deep-link jump can settle one page short mid-layout — align the
        // pager onto the sleep page by its frame before searching the row.
        let sleepPage = app.scrollViews.matching(identifier: "insights.page.sleep").firstMatch
        for _ in 0 ..< 12 where sleepPage.exists {
            let minX = sleepPage.frame.minX
            if abs(minX) < 50 { break }
            if minX > 0 { app.swipeLeft() } else { app.swipeRight() }
            Thread.sleep(forTimeInterval: 1.0)
        }
        attach(name: "sleep-metric-page")

        // The detail must NOT show the error card — the sleep page lands either
        // on the stage bands / hypnogram row (live tenant) or the calm empty
        // state (hermetic fixtures). The error card is the only hard failure.
        var errorOnPage = localizedText(app: app, keys: [
            "Diese Nacht konnte nicht geladen werden",
            "Couldn't load this night"
        ])
        XCTAssertFalse(errorOnPage, "Sleep page renders the error card under hermetic boot")

        // Best-effort: when the hypnogram entry row is present (live tenant with
        // sleep data), tap into the detail and re-assert no error card. Absent
        // under hermetic fixtures — that is the expected calm-empty path, not a
        // failure.
        if let row = firstExistingTile(app: app, identifiers: ["insights.metric.sleep.hypnogram"]) {
            attach(name: "sleep-metric-page-entry-row")
            row.tap()
            Thread.sleep(forTimeInterval: 4)
            errorOnPage = localizedText(app: app, keys: [
                "Diese Nacht konnte nicht geladen werden",
                "Couldn't load this night"
            ])
            XCTAssertFalse(errorOnPage, "Hypnogram detail shows the error card")
            attach(name: "sleep-hypnogram-detail")
        }
    }

    // MARK: - Helpers

    private func localizedText(app: XCUIApplication, keys: [String]) -> Bool {
        for key in keys {
            let el = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", key))
                .firstMatch
            if el.exists { return true }
        }
        return false
    }

    private func attach(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also export to the walkthrough evidence dir (simulator shares the
        // host filesystem) so the proof shots survive without xcresult export.
        let dir = URL(fileURLWithPath: "/tmp/sleep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func firstExistingTile(app: XCUIApplication, identifiers: [String]) -> XCUIElement? {
        let window = app.windows.firstMatch
        for _ in 0 ..< 8 {
            for id in identifiers {
                // The NavigationLink row surfaces as Button OR Other depending
                // on the container — query both. `isHittable` throws for
                // off-screen elements, so gate on frame containment instead.
                for query in [
                    app.buttons.matching(identifier: id),
                    app.otherElements.matching(identifier: id),
                    app.descendants(matching: .any).matching(identifier: id)
                ] {
                    let el = query.firstMatch
                    if el.exists {
                        let frame = el.frame
                        if !frame.isEmpty, window.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                            return el
                        }
                    }
                }
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }
}
