import XCTest

/// Marketing-asset capture run. Drives the live `demo.healthlog.dev` tenant in
/// **English** (`-AppleLanguages (en)` / `-AppleLocale en_US`) and writes
/// full-resolution PNGs of the strongest hero surfaces directly to the host
/// filesystem at `/tmp/marketing-shots/` (the simulator shares the host FS for
/// absolute paths — the sleep/assessment render walkthroughs use the same
/// trick). Each shot is also attached to the `xcresult` bundle as a backup.
///
/// This is **not** a regression gate — its assertions are deliberately soft
/// (a missing surface logs + skips rather than fails) so a single empty page on
/// the demo tenant never aborts the whole capture run. The orchestrator reviews
/// the PNGs by eye and hands the best ones to the operator.
///
/// Reuses the demo-login walk from `WalkthroughDashboardTest`
/// (Welcome → custom server URL → email+password → skip onboarding), the only
/// proven path that lands on a populated tenant.
@MainActor
final class MarketingScreenshotsTest: XCTestCase {
    private let outputDir = "/tmp/marketing-shots"

    override func setUpWithError() throws {
        continueAfterFailure = true
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir),
            withIntermediateDirectories: true
        )
    }

    func test_capture_marketing_hero_screenshots() {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot with deterministic
        // English locale for the marketing captures. Fixture data (greeting +
        // tiles) renders the hero surfaces without the live demo tenant.
        let greeting = app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ],
            timeout: 120
        )
        // Belt-and-braces — the ack fixture + flag already keep the gate down,
        // but dismiss it if it somehow surfaces on a reused sim.
        dismissDisclaimerAck(app: app)
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 120),
            "Dashboard greeting did not appear under hermetic boot"
        )

        // --- 01 Dashboard (health-score ring + tiles, above the fold) ---
        // Dismiss the "Connect Apple Health" banner first — the demo tenant has
        // no local HealthKit grant, so it always shows; "Not now" removes it for
        // a calmer hero shot (and prevents a later stray tap on its Connect CTA
        // from raising the modal system auth sheet).
        dismissDisclaimerAck(app: app)
        dismissAIConsentSheet(app: app)
        let bannerDismiss = app.buttons["healthkitConnectBanner.dismissButton"]
        if bannerDismiss.waitForExistence(timeout: 6), bannerDismiss.isHittable {
            bannerDismiss.tap()
        }
        // Let the loading skeleton resolve + the sync footer settle before the
        // hero capture (the first paint shows "Preparing your data…").
        settle(12)
        capture(name: "01-dashboard")

        // --- 02 Dashboard scrolled (metric tile-strip with sparklines) ---
        // Swipe from the bottom edge so the gesture never lands on the
        // "Connect Apple Health" banner button (a tap there opens the system
        // HealthKit auth sheet, which is modal and hijacks every later shot).
        swipeUpFromBottom(app: app)
        settle(3)
        dismissSystemHealthSheet()
        capture(name: "02-dashboard-tiles")

        // --- 03 Insights overview (Vitals + Targets cards) ---
        dismissSystemHealthSheet()
        let insightsTab = app.buttons["Insights"]
        if insightsTab.waitForExistence(timeout: 10) {
            insightsTab.tap()
            _ = app.staticTexts["insights.page.header.title.overview"].waitForExistence(timeout: 20)
            settle(5)
            capture(name: "03-insights-overview")
        } else {
            logSkip("Insights tab not reachable")
        }

        // --- 04 Insights: blood-pressure metric page (rich chart on demo) ---
        captureInsightsMetric(app: app, slug: "blood-pressure", shot: "04-insights-blood-pressure")

        // --- 05 Insights: weight metric page (long, smooth trend on demo) ---
        captureInsightsMetric(app: app, slug: "weight", shot: "05-insights-weight")

        // --- 06 Insights: pulse metric page (rich heart-rate trend on demo) ---
        // (recovery is a server-composite special page without a stable metric
        // deep-link route — it landed back on weight, so we chart pulse instead,
        // which has dense demo data and a proper chartable slug.)
        captureInsightsMetric(app: app, slug: "pulse", shot: "06-insights-pulse")

        // --- 07 Sleep hypnogram (stage bands) ---
        openDeepLink("healthlog://insights/sleep")
        settle(6)
        alignInsightsPage(app: app, identifier: "insights.page.sleep")
        let hypnogramRow = firstExistingTile(
            app: app, identifiers: ["insights.metric.sleep.hypnogram"]
        )
        if let hypnogramRow {
            hypnogramRow.tap()
            settle(5)
            capture(name: "07-sleep-hypnogram")
        } else {
            // The sleep metric page itself is still a strong shot — capture it.
            capture(name: "07-sleep-page")
            logSkip("Sleep hypnogram entry row not found — captured sleep page instead")
        }

        // --- 08 Medications (active meds + compliance) ---
        openDeepLink("healthlog://medications")
        settle(5)
        capture(name: "08-medications")

        // --- 09 Coach (conversation / ask-coach surface) ---
        captureCoach(app: app)
    }

    // MARK: - Surface helpers

    /// Opens an Insights metric page via deep link, aligns the pager onto it,
    /// and captures both the chart and a scrolled-down editorial view.
    private func captureInsightsMetric(app: XCUIApplication, slug: String, shot: String) {
        openDeepLink("healthlog://insights/\(slug)")
        settle(6)
        alignInsightsPage(app: app, identifier: "insights.page.\(slug)")
        capture(name: shot)
    }

    /// The coach lives behind a floating button (`AuthenticatedShell.coachFloatingButton`)
    /// that opens `AskCoachSheet`, OR a deep link (`healthlog://coach`). The
    /// floating button only mounts when AI is configured; if neither path opens
    /// a populated coach surface, we log + skip (no marketing value in an empty
    /// consent prompt).
    private func captureCoach(app: XCUIApplication) {
        // The sample Coach conversation lives behind the AI-consent gate. For the
        // hero shots above we Decline the gate for a clean dashboard; here we
        // grant it (tap "Accept") so the coach affordance mounts and the seeded
        // conversation renders. The Accept mints a server receipt; on the
        // read-only demo that POST may no-op, but the existing conversation is
        // still viewable, which is all the marketing shot needs.
        openDeepLink("healthlog://coach")
        settle(2)
        for label in ["Accept", "Akzeptieren", "Allow", "Erlauben"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(3)
                break
            }
        }
        let coachButton = app.buttons["AuthenticatedShell.coachFloatingButton"]
        if coachButton.waitForExistence(timeout: 4), coachButton.isHittable {
            coachButton.tap()
            settle(4)
            capture(name: "09-coach")
            return
        }
        openDeepLink("healthlog://coach")
        settle(4)
        // Only keep the shot if the coach sheet actually surfaced — look for the
        // ask-coach input row / transcript chrome.
        let coachSurface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'AskCoach'"))
            .firstMatch
        if coachSurface.waitForExistence(timeout: 5) {
            capture(name: "09-coach")
        } else {
            logSkip("Coach surface not reachable (AI likely unconfigured on demo tenant)")
        }
    }

    /// A deep-link `insights` jump can settle one page short mid-layout — align
    /// the pager onto the target page by its frame before capturing.
    private func alignInsightsPage(app: XCUIApplication, identifier: String) {
        let page = app.scrollViews.matching(identifier: identifier).firstMatch
        for _ in 0 ..< 12 where page.exists {
            let minX = page.frame.minX
            if abs(minX) < 50 { break }
            if minX > 0 { app.swipeLeft() } else { app.swipeRight() }
            settle(1)
        }
    }

    private func openDeepLink(_ string: String) {
        dismissSystemHealthSheet()
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    /// Swipes up from near the bottom safe area so the gesture's start point is
    /// well below the dashboard's "Connect Apple Health" banner — a stray tap on
    /// that banner opens the modal system HealthKit auth sheet, which then covers
    /// every subsequent surface.
    private func swipeUpFromBottom(app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Dismisses the springboard-owned system HealthKit auth sheet / alert if it
    /// is on screen (it can be triggered by a stray tap on the dashboard Connect
    /// banner). We tap "Don't Allow" / "Cancel" / "OK" so we never grant — the
    /// demo tenant's data comes from the server, not local HealthKit, so denying
    /// keeps the captures clean. Queries the springboard process because the
    /// sheet is NOT part of our app's element tree.
    private func dismissSystemHealthSheet() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The HK flow can stack a confirm popover ("OK") on top of the main auth
        // sheet ("Don't Allow"), so dismiss repeatedly until no known dismiss
        // affordance remains. Deny-first labels come before "OK" so we never
        // grant (the demo data is server-side).
        let labels = [
            "Don't Allow", "Don’t Allow", "Nicht erlauben",
            "Cancel", "Abbrechen", "OK"
        ]
        for _ in 0 ..< 4 {
            var tapped = false
            for label in labels {
                let button = springboard.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    settle(1)
                    tapped = true
                    break
                }
            }
            if !tapped { return }
        }
    }

    // MARK: - Capture primitives

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Writes a full-resolution PNG to `/tmp/marketing-shots/<name>.png` and
    /// attaches it to the result bundle as a backup.
    private func capture(name: String) {
        // Defensive: a stray tap may have raised the modal system HealthKit auth
        // sheet, which would otherwise sit on top of the surface we want.
        dismissSystemHealthSheet()
        // F5 (v1.18.6) — the one-time medical-disclaimer ack sheet can surface a
        // beat after the dashboard greeting resolves (it is presented by RootView
        // on the authenticated shell, behind which the greeting already exists),
        // so it would otherwise sit on top of every hero shot. Clear it here too.
        let liveApp = XCUIApplication()
        if dismissDisclaimerAck(app: liveApp) {
            settle(2)
        }
        // The AI-consent gate ("Enable assistant insights" / Data flow) auto-
        // presents on the authenticated shell because the demo seed configures
        // an AI provider for the sample Coach conversation. Decline it so the
        // hero surfaces are not covered — Decline closes instantly with no
        // server round-trip (Accept would mint a consent receipt). The Coach
        // shot uses its own path below.
        if dismissAIConsentSheet(app: liveApp) {
            settle(2)
        }
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        do {
            try shot.pngRepresentation.write(to: url)
        } catch {
            let miss = XCTAttachment(string: "Failed to write \(name): \(error)")
            miss.name = "\(name)-write-error"
            miss.lifetime = .keepAlways
            add(miss)
        }
    }

    private func logSkip(_ reason: String) {
        let note = XCTAttachment(string: reason)
        note.name = "skip-note"
        note.lifetime = .keepAlways
        add(note)
    }

    private func firstExistingTile(app: XCUIApplication, identifiers: [String]) -> XCUIElement? {
        for _ in 0 ..< 6 {
            for id in identifiers {
                let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
                if el.exists, el.isHittable { return el }
            }
            app.swipeUp()
            settle(0.5)
        }
        return nil
    }

    /// F5 (v1.18.6 DISC-02) — dismisses the one-time medical-disclaimer
    /// acknowledgment sheet (`MedicalDisclaimerAckSheet`, CTA
    /// `disclaimer.ack.confirm`) that RootView presents once on the first
    /// authenticated launch of a fresh sim. Returns `true` if it tapped.
    @discardableResult
    private func dismissDisclaimerAck(app: XCUIApplication) -> Bool {
        let confirm = app.buttons["disclaimer.ack.confirm"]
        if confirm.waitForExistence(timeout: 2), confirm.isHittable {
            confirm.tap()
            settle(1)
            return true
        }
        return false
    }

    /// Dismisses the auto-presented AI-consent gate (`AIConsentSheet`,
    /// "Enable assistant insights") by tapping its nav-bar "Decline" action.
    /// Returns `true` if it tapped.
    @discardableResult
    private func dismissAIConsentSheet(app: XCUIApplication) -> Bool {
        for label in ["Decline", "Ablehnen"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(1)
                return true
            }
        }
        return false
    }
}
