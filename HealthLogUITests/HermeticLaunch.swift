import XCTest

/// **W-HERMETIC-E2E (v0152).** Shared hermetic launch helper for the walkthrough
/// UITests. Replaces the fragile live-`demo.healthlog.dev` onboarding walk with a
/// deterministic, NETWORK-FREE boot: the `-uitest-hermetic` launch argument seeds
/// an authenticated session backed by bundled JSON fixtures (see
/// `HealthLog/App/HermeticUITestSupport.swift` + `HermeticFixtures.swift`), so the
/// app comes up straight on the Dashboard with deterministic fixture data and no
/// server dependency.
extension XCUIApplication {
    /// Launch the app hermetically and wait for the Dashboard greeting. The
    /// greeting is the universal "we are inside the authenticated shell" signal
    /// every walkthrough test keys off.
    @discardableResult
    func launchHermeticAndWaitForDashboard(
        extraArguments: [String] = [],
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        launchArguments += [
            "-uitest-hermetic",
            // Belt-and-braces: the disclaimer fixture already acks, but this
            // flag covers the standalone/local ack path too.
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock"
        ] + extraArguments
        launch()

        let greeting = staticTexts["dashboard.greeting"]
        XCTAssertTrue(
            greeting.waitForExistence(timeout: timeout),
            "Hermetic boot did not reach the Dashboard greeting — check the fixture seed",
            file: file,
            line: line
        )
        return greeting
    }
}

/// **Phase 08 Wave 0.** Typed launch helpers for the Phase-8 UI REDs.
///
/// Every helper waits for a *scenario-specific* ready identifier before its
/// caller asserts anything, so a Phase-8 RED can only ever fail at the named
/// product assertion. A boot that never reaches its screen fails here, with the
/// hierarchy and a screenshot attached, and the behavioural-RED harness rejects
/// that as infrastructure rather than counting it.
enum Phase8Scenario: String {
    case releaseSurface
    case documentsDelayedFilter
    case documentsPartialBulk
    case documentsModuleDisabled
    case returningLoginCompleted
    /// **08-08.** The same unauthenticated boot for an account whose setup is
    /// genuinely outstanding. A case that asserts about the optional tail has to
    /// ask for it now: since the post-authentication route reads the server's
    /// completion flag, `returningLoginCompleted` goes straight to the shell.
    case returningLoginIncomplete
    case onboardingProfileFailure
    /// **08-11.** The shell with four renderable wellness scores on the derived
    /// batch route, so the Insights score grid has tiles to lay out.
    case insightsAccessibility
}

extension XCUIApplication {
    /// Boot straight into the authenticated shell under a Phase-8 scenario and
    /// wait for the Dashboard greeting.
    @discardableResult
    func launchPhase8Shell(
        _ scenario: Phase8Scenario,
        extraArguments: [String] = [],
        timeout: TimeInterval = 40,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        launchHermeticAndWaitForDashboard(
            extraArguments: ["-uitest-phase8", scenario.rawValue] + extraArguments,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /// Boot UNAUTHENTICATED onto the onboarding auth step under a Phase-8
    /// scenario and wait for the password-login affordance.
    @discardableResult
    func launchPhase8Onboarding(
        _ scenario: Phase8Scenario,
        extraArguments: [String] = [],
        timeout: TimeInterval = 40,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        launchArguments += [
            "-uitest-auth-journey",
            "-uitest-ack-disclaimer",
            "-uitest-disable-biometric-lock",
            "-uitest-phase8",
            scenario.rawValue
        ] + extraArguments
        launch()

        let login = buttons["onboarding.passwordLoginCTA"]
        XCTAssertTrue(
            login.waitForExistence(timeout: timeout),
            "Phase-8 onboarding boot did not reach the password-login affordance",
            file: file,
            line: line
        )
        return login
    }

    /// Wait for an element that a Phase-8 assertion is about to read, and say
    /// which screen was expected when it never arrives.
    @discardableResult
    func awaitPhase8(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let arrived = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(arrived, "Phase-8 precondition never appeared: \(what)", file: file, line: line)
        return arrived
    }

    /// The tab-bar button carrying `symbol`. `TabContent` drops accessibility
    /// identifiers (see `AuthenticatedShell`), so the SF Symbol is the landmark.
    func phase8Tab(_ symbol: String) -> XCUIElement {
        tabBars.buttons.containing(.image, identifier: symbol).firstMatch
    }

    /// An element by identifier, without asserting its element type. A SwiftUI
    /// row carrying `.accessibilityIdentifier` resolves to a button, a cell or a
    /// plain element depending on how it was composed, and a Phase-8 RED must
    /// never fail because the wrapper changed shape.
    func phase8Element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// Scrolls a lazily-built list until `identifier` exists.
    ///
    /// The Settings hub builds sixteen rows and only renders what fits, so
    /// `waitForExistence` on a trailing row (About, Privacy & Security) can
    /// never succeed from the top. Bounded, and reports how far it got.
    @discardableResult
    func scrollToPhase8(
        _ identifier: String,
        swipes: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = phase8Element(identifier)
        for _ in 0 ..< swipes {
            if element.exists, element.isHittable { return element }
            swipeUp()
        }
        XCTAssertTrue(
            element.exists,
            "Phase-8 precondition never scrolled into view: \(identifier)",
            file: file,
            line: line
        )
        return element
    }

    /// The **probe** form of ``scrollToPhase8(_:swipes:file:line:)`` — scrolls
    /// the same way and reports what it found, without asserting.
    ///
    /// The two are not interchangeable and the difference is not stylistic. A
    /// RED that asks "is this surface still reachable?" must be able to observe
    /// "no", because "no" is the state the fix produces. Using the precondition
    /// form for that question hides the closure behind a harness failure: when
    /// 08-06 deleted the local clinical-attestation row, the support-gate RED
    /// stopped reporting its own violation and started failing with "precondition
    /// never scrolled into view" — a red test that no longer said anything about
    /// the product. Reach for `scrollToPhase8` when the element is a precondition
    /// of the walkthrough, and for this when its absence is a possible answer.
    func probePhase8(_ identifier: String, swipes: Int = 8) -> XCUIElement? {
        let element = phase8Element(identifier)
        for _ in 0 ..< swipes {
            if element.exists, element.isHittable { return element }
            swipeUp()
        }
        return element.exists ? element : nil
    }
}

extension XCTestCase {
    /// **CU-05.** Attach "what was on screen instead" right before a walkthrough
    /// assertion fails.
    ///
    /// The Insights walkthroughs used to fail with a bare "header missing" /
    /// "pager missing", which says nothing about WHY — and the interesting cases
    /// are exactly the ones where the app's own subtree is not the top of the
    /// screen at all (a system permission sheet, an alert, a stuck gate). The
    /// hierarchy dump plus the screenshot answer that in one look, so the next
    /// flake is diagnosed from the result bundle instead of re-derived by hand.
    /// Only ever runs on the failing branch, so a green run pays nothing.
    @MainActor
    func attachFailureDiagnostics(app: XCUIApplication, label: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(label)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(label)-screen"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
