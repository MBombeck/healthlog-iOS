import XCTest

/// **v0.5.4.1 walkthrough validator.** Drives the demo-login flow end-to-end
/// on the simulator and captures a Dashboard screenshot for visual review.
///
/// Why an XCUI test instead of a snapshot or unit fixture: the v0.5.4 bugs
/// the operator caught (Briefing-Hero rendering raw identifiers, Tile-Strip
/// collapsed to two cards, profile-avatar misplacement, overdue intakes
/// missing, duplicate Einstellungen row) are surface-level visual regressions
/// that pure unit suites couldn't catch — they pass on the dataset but read
/// as broken to a real user. This driver walks the same path the operator
/// did and asserts on the rendered tree.
/// The test uses hermetic fixture launch arguments and exercises the ordinary
/// server-address plus email/password UI. It never depends on reviewer
/// credentials or a live backend.
///
/// **Lazy-grid note:** the per-kind metric tiles render in a `LazyVGrid`, so
/// rows below the fold are not instantiated into the accessibility tree until
/// they scroll into view. The tile assertions scroll the grid into view
/// (`scrollToTile`) instead of assuming an above-the-fold paint.
@MainActor
final class WalkthroughDashboardTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_dashboard_renders_correctly_after_demo_login() {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot. The app comes up
        // authenticated against bundled fixtures (greeting + per-kind tiles +
        // sparklines), so this test no longer depends on `demo.healthlog.dev`.
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)

        // Give the dashboard a moment to fan out + repaint.
        Thread.sleep(forTimeInterval: 5)

        // 6. Screenshot for visual review.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "dashboard-after-demo-login"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Full AX hierarchy dump so future audits can interrogate what
        // tiles were on screen without re-running the simulator.
        let debugDump = app.debugDescription
        let dumpAttachment = XCTAttachment(string: debugDump)
        dumpAttachment.name = "dashboard-ax-hierarchy"
        dumpAttachment.lifetime = .keepAlways
        add(dumpAttachment)

        // 7. Briefing hero must NOT show raw identifier leak.
        let identifierLeakPredicate = NSPredicate(format: "label MATCHES %@", ".*on_device_[0-9]+.*")
        let leaks = app.staticTexts.containing(identifierLeakPredicate)
        XCTAssertEqual(leaks.count, 0, "Briefing hero leaked an `on_device_*` identifier string")

        // 8. Avatar exists and lives in the upper section of the screen
        // — pin the y-coordinate so a future regression that pushes the
        // avatar into a toolbar slot fails loudly.
        let avatar = app.buttons["dashboard.profile.avatar"]
        XCTAssertTrue(avatar.exists, "Inline profile avatar missing from greeting row")
        XCTAssertLessThan(avatar.frame.minY, 300, "Avatar must be near top, inline with greeting")
        XCTAssertGreaterThan(avatar.frame.minY, 30, "Avatar must NOT be in the navigation chrome")

        // 8a. v0.5.4.3 HP1 — Gravatar render evidence. The operator's
        // walkthrough on v0.5.4.2 caught the Dashboard avatar painting
        // empty (initials-only) even for emails with a registered
        // Gravatar. We capture an isolated screenshot of the avatar's
        // frame so the operator-review can visually confirm an actual
        // image (Gravatar photo OR identicon pattern) painted, rather
        // than a flat purple gradient circle. Give the AsyncImage 6s of
        // additional headroom to complete its CDN round-trip before
        // sampling — the Dashboard host re-renders frequently, and we
        // want to attach the *settled* state.
        Thread.sleep(forTimeInterval: 6)
        let avatarScreenshot = avatar.screenshot()
        let avatarAttachment = XCTAttachment(screenshot: avatarScreenshot)
        avatarAttachment.name = "dashboard-profile-avatar-render"
        avatarAttachment.lifetime = .keepAlways
        add(avatarAttachment)

        // 8b. The per-kind metric tiles render in a `LazyVGrid`, which does
        // not instantiate off-screen rows into the AX tree, so the tile
        // assertions below must first scroll the grid into view rather than
        // assume it paints above the fold. We swipe up once to bring the
        // metric tiles on-screen; the greeting + avatar assertions above
        // already ran against the top of the scroll, so scrolling now is safe.
        app.swipeUp()
        // Let the LazyVGrid instantiate the now-visible rows + the scroll
        // settle before we interrogate the tree.
        Thread.sleep(forTimeInterval: 1)

        // 9. Tile-strip non-collapse guard. The dashboard must surface at
        // least one per-kind tile when the server emits metric data —
        // BF-1 collapsed the entire strip on a fresh device with HK
        // locked. We match on the kind-label substrings the live demo
        // tenant carries (Gewicht / Blutdruck / Puls). Any single one
        // counts as proof the strip is alive.
        let tileLabels = ["Gewicht", "Blutdruck", "Puls"]
        let tilePredicate = NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
            tileLabels[0],
            tileLabels[1],
            tileLabels[2]
        )
        // Wait for the first per-kind tile to materialise after the scroll
        // (the glass-toolbar repaint can delay the LazyVGrid instantiation a
        // beat) before counting.
        _ = app.buttons.containing(tilePredicate).firstMatch.waitForExistence(timeout: 8)
        let tileMatch = app.buttons.containing(tilePredicate).count
        XCTAssertGreaterThan(tileMatch, 0, "Dashboard tile-strip must surface at least one per-kind tile")

        // 10. **v0.5.4.3-HP3.** Schritte tile must render today's day-
        // cumulative — never the latest single sample. The tile-value
        // text leaf carries `accessibilityIdentifier == "tile.steps.value"`
        // (HLDashboardTile valueRow). We resolve the leaf, dump its label
        // for forensics, and assert it is non-empty + non-em-dash + parses
        // as an integer when the demo tenant has step data. If the Schritte
        // tile isn't in the rendered set (operator hid it via dashboard
        // customisation, or the demo tenant emits no STEPS row), we log
        // the absence + skip the numeric assertion — the screenshot still
        // gets attached so the operator can visually confirm.
        let stepsValueLeaf = app.staticTexts["tile.steps.value"]
        if stepsValueLeaf.waitForExistence(timeout: 8) {
            let raw = stepsValueLeaf.label
            let stepsAttachment = XCTAttachment(string: "tile.steps.value label=\(raw)")
            stepsAttachment.name = "steps-tile-value"
            stepsAttachment.lifetime = .keepAlways
            add(stepsAttachment)

            XCTAssertFalse(raw.isEmpty, "Steps tile rendered an empty value")
            XCTAssertNotEqual(raw, "—", "Steps tile rendered the em-dash placeholder — demo tenant should carry today step data")
            // Strip grouping separators (`.` DE, `,` EN) and assert the
            // remaining string parses as Int. The day-cumulative for a demo
            // user with Apple Health data is typically in the thousands.
            let digits = raw.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
            XCTAssertNotNil(Int(digits), "Steps tile value \(raw) is not an integer once group separators are stripped")
        } else {
            let absentAttachment = XCTAttachment(string: "tile.steps.value not present in tree")
            absentAttachment.name = "steps-tile-absent"
            absentAttachment.lifetime = .keepAlways
            add(absentAttachment)
        }

        // 11. **V0.5.4.3 HP-2 — sparkline-presence assertion for BP + Puls.**
        // Persistent bug since v0.5.1: BP and Puls tiles render the value but
        // no chart. Three prior fix attempts (V052-A1 B2 hydration, V053-D23
        // universal sparkline, V054-BF234 tile correctness) each landed unit-
        // green but the operator real-device walkthrough kept reporting BP +
        // Puls chartless. This XCUI assertion locks the regression at the
        // tile-state level: the tile's accessibility identifier carries the
        // `withChart` / `noChart` suffix encoded from
        // `HLDashboardTile.sparklineValues.count >= 2`, so a regression that
        // silently drops the chart fails the walkthrough rather than slipping
        // through. Demo-tenant has 53 BP + 53 Puls readings (verified via
        // `/api/dashboard/summary` + `/api/measurements?limit=400` against
        // `demo.healthlog.dev` on 2026-05-18) — the chart MUST paint.
        //
        // The BP + Puls tiles can sit below the fold inside the LazyVGrid, so
        // scroll each tile into view before asserting on its `withChart` state
        // rather than relying on it painting in the initial visible window.
        let bpWithChart = scrollToTile(app: app, identifier: "tile.bloodPressure.withChart")
        XCTAssertTrue(
            bpWithChart.waitForExistence(timeout: 5),
            "BP tile is rendering without a chart — sparkline regression. " +
                "Check sparkline-derivation path: server summary → DashboardStore hydration → " +
                "HLDashboardTile.sparklineValues → MetricSeriesProjection.systolicOnly."
        )
        let pulseWithChart = scrollToTile(app: app, identifier: "tile.pulse.withChart")
        XCTAssertTrue(
            pulseWithChart.waitForExistence(timeout: 5),
            "Puls tile is rendering without a chart — sparkline regression. " +
                "Check sparkline-derivation path: server summary → DashboardStore hydration → " +
                "HLDashboardTile.sparklineValues → MetricSeriesProjection.heartRate."
        )
    }

    /// Scrolls the dashboard until the tile with `identifier` materialises in
    /// the accessibility tree, then returns the element.
    ///
    /// The dashboard metric grid is a `LazyVGrid`, so tiles below the fold are
    /// not instantiated into the tree until they scroll into view. The BP /
    /// Puls tiles can start below the initial visible window. We swipe up a
    /// bounded number of times (the grid is short — six tiles max) until the element
    /// exists or we hit the bottom; returning the (possibly still-absent)
    /// element lets the caller's `waitForExistence` produce the original
    /// diagnostic message on a genuine sparkline regression.
    private func scrollToTile(app: XCUIApplication, identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        var attempts = 0
        while !element.exists, attempts < 6 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
            attempts += 1
        }
        return element
    }

    /// **v0.5.5 — Mehr-header layout walkthrough.**
    ///
    /// The Mehr-tab header reads `[Mehr title] [Spacer] [Gear]` — gear on
    /// the trailing edge so the operator's "settings = top-right" mental
    /// model carries through (matches Apple's Health, Fitness, and system
    /// Settings app placement). Drives the SettingsScreen push from a
    /// plain `Button` + `.navigationDestination(isPresented:)` so the
    /// list-row chevron the operator flagged on v0.5.4.2 stays
    /// structurally impossible.
    ///
    /// This test:
    /// 1. Lands on the Dashboard (via the same demo-login walk the sibling
    ///    test uses, short-circuited when already authenticated).
    /// 2. Taps the "Mehr" tab.
    /// 3. Asserts the gear button (`more.toolbar.gear`) is on the RIGHT
    ///    side of the header — `frame.minX > screenMidX` keeps the gear
    ///    in the trailing half of the 393 pt logical width while
    ///    tolerating safe-area padding shifts across iOS versions.
    /// 4. Asserts no `chevron.right` image lives near the gear (sanity-
    ///    check against the NavigationLink-shaped regression).
    /// 5. Taps the gear and asserts SettingsScreen surfaces (navigation
    ///    title "Einstellungen").
    func test_mehr_header_gear_is_right_of_title() {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot.
        _ = app.launchHermeticAndWaitForDashboard(timeout: 60)

        // Walk to the Mehr tab. Tab-bar items expose their localised title
        // as the AX label (`Tab("More", ...)` in `AuthenticatedShell`).
        let mehrTab = app.buttons["Mehr"]
        XCTAssertTrue(mehrTab.waitForExistence(timeout: 10), "Mehr tab button missing from tab-bar")
        mehrTab.tap()

        // Header gear must exist + sit on the trailing half of the screen.
        // We don't pin the exact x-coordinate (Liquid Glass + safe-area
        // padding can shift it a few points across iOS versions); the
        // screen-midpoint floor is a comfortable threshold that still
        // catches a leading-edge regression on iPhone 17 Pro
        // (393 pt logical width).
        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Gear button missing from Mehr header")
        let screenMidX = XCUIApplication().frame.midX
        XCTAssertGreaterThan(
            gear.frame.minX,
            screenMidX,
            "Gear must sit on the RIGHT of the Mehr header (trailing edge), not the leading edge"
        )

        // Mehr title must be present (this also confirms we landed on
        // MoreScreen, not a sub-route).
        let mehrTitle = app.staticTexts["Mehr"]
        XCTAssertTrue(mehrTitle.waitForExistence(timeout: 5), "Mehr title missing from header")
        // Title sits to the LEFT of the gear → `minX(title) < minX(gear)`.
        XCTAssertLessThan(mehrTitle.frame.minX, gear.frame.minX, "Title must render to the left of the gear button")

        // Screenshot for visual review.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "mehr-header-trailing-gear"
        attachment.lifetime = .keepAlways
        add(attachment)

        // No list-row chevron must be vertically aligned with the gear.
        // We look for any `chevron.right` image whose centre Y is within
        // ±20pt of the gear's centre Y — that's the regression footprint
        // the operator flagged on v0.5.4.2 (chevron-as-trailing-affordance
        // next to the icon). The MoreScreen list-rows below still ship
        // their own NavigationLink chevrons, but those sit well below the
        // header band.
        let chevrons = app.images.matching(identifier: "chevron.right").allElementsBoundByIndex
        for chevron in chevrons where chevron.exists {
            let aligned = abs(chevron.frame.midY - gear.frame.midY) < 20
            XCTAssertFalse(
                aligned,
                "A chevron.right image is vertically aligned with the header gear — the operator-flagged regression has returned"
            )
        }

        // Tap the gear → SettingsScreen pushes. The Settings landing surface
        // carries the "Einstellungen" navigation title (DE).
        gear.tap()
        let settingsTitle = app.navigationBars["Einstellungen"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Tapping the gear must push SettingsScreen")
    }
}
