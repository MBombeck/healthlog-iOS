import XCTest

/// **v0.14.8 W2 follow-up #3 — dedicated cycle-toggle flip driver.**
///
/// The W2 walkthrough could only verify the cycle opt-in via a defaults seed
/// (`-hl.settings.cycleTracking.optIn YES`) because `switch.tap()` on the
/// SwiftUI toggle did not register. This test drives the actual flip path:
/// More → Settings → Integrations → Apple Health → "Weitere
/// Synchronisierungen" → cycle toggle, asserting the rendered switch value
/// transitions `0 → 1`. Tap strategy: prefer the nested
/// `switches.firstMatch` child (SwiftUI exposes Toggle as a container whose
/// tappable switch is a descendant), falling back to a coordinate tap on the
/// trailing edge where the UISwitch lives.
@MainActor
final class CycleToggleFlipUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_cycle_toggle_flips_on_via_settings() {
        let app = XCUIApplication()
        // W-HERMETIC-E2E (v0152) — network-free hermetic boot. The cycleTracking
        // feature flag is ON in the fixture so the toggle surface is reachable.
        _ = app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                // Deterministic start state: opt-in OFF.
                "-hl.settings.cycleTracking.optIn", "NO"
            ],
            timeout: 60
        )

        // More tab → gear → Integrations → Apple Health.
        let moreTab = app.tabBars.buttons.element(boundBy: max(0, app.tabBars.buttons.count - 1))
        XCTAssertTrue(moreTab.waitForExistence(timeout: 10), "More tab missing")
        moreTab.tap()

        let gear = app.buttons["more.toolbar.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "Settings gear missing")
        gear.tap()

        let integrationsRow = app.descendants(matching: .any)
            .matching(identifier: "settings.hub.integrations").firstMatch
        XCTAssertTrue(integrationsRow.waitForExistence(timeout: 10), "Integrations hub row missing")
        integrationsRow.tap()

        let appleHealthRow = app.descendants(matching: .any)
            .matching(identifier: "settings.integrations.appleHealthRow").firstMatch
        XCTAssertTrue(appleHealthRow.waitForExistence(timeout: 10), "Apple-Health row missing")
        appleHealthRow.tap()

        // A2 (b244): a not-yet-eligible user (opt-in OFF, non-female fixture)
        // now sees the neutral "Zyklus-Tracking aktivieren?" OFFER instead of a
        // live-looking toggle. Drive the real opt-in path — expand the offer,
        // confirm — then assert the toggle now renders ON: opting in flips the
        // CycleGate to available, so the presentation switches to the real toggle.
        // The special-syncs card sits below the data-type card — scroll it in.
        let offer = app.descendants(matching: .any)
            .matching(identifier: "HealthAccess.cycleTrackingOffer").firstMatch
        var scrolls = 0
        while !offer.exists, scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(
            offer.waitForExistence(timeout: 10),
            "Cycle opt-in offer missing — is FeatureFlag.cycleTracking off on the demo server?"
        )
        offer.tap()

        let confirm = app.descendants(matching: .any)
            .matching(identifier: "HealthAccess.cycleTrackingOfferConfirm").firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "Opt-in confirm button missing after expanding the offer"
        )
        confirm.tap()

        // Opting in flips the gate available → the presentation becomes the real
        // toggle, rendered ON (optimistic).
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "HealthAccess.cycleTrackingToggle").firstMatch
        scrolls = 0
        while !toggle.exists, scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(
            waitForSwitchValue("1", of: toggle, in: app, timeout: 10),
            "Cycle toggle did not render ON after opting in via the offer (value \(String(describing: toggle.value)))"
        )
    }

    // MARK: - Switch value plumbing

    /// SwiftUI exposes `Toggle` either as a switch itself or as a container
    /// whose first switch descendant carries the value.
    private func switchValue(of element: XCUIElement, in app: XCUIApplication) -> String? {
        let nested = element.switches.firstMatch
        let carrier = nested.exists ? nested : element
        return carrier.value as? String
    }

    private func waitForSwitchValue(
        _ expected: String,
        of element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if switchValue(of: element, in: app) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return switchValue(of: element, in: app) == expected
    }
}
