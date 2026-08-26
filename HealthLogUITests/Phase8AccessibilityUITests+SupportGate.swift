import XCTest

/// **Phase 08 Plan 15 — the three legs of `testSupportDiagnosticsRequireConfirmation`.**
///
/// In a sibling `extension` rather than in the class, for the reason 08-08
/// established: a test type that grows a leg at a time eventually trips
/// `type_body_length`, and the strict baseline refuses a new warning. The case
/// census is unchanged — `test`-prefixed methods are counted, not files.
///
/// **Each leg boots its own app.** Walking back up three navigation levels
/// between legs is the kind of thing that fails for reasons that have nothing
/// to do with the boundary being measured; a fresh hermetic boot costs seconds
/// and cannot leave the previous leg's screen on the stack.
///
/// **Preconditions assert, answers probe.** Reaching Settings → Notifications →
/// Advanced diagnostics is a product claim in its own right ("a user whose
/// banner never arrives can find out where it stops"), so the navigation legs
/// use the asserting helpers. Whether an engineering instrument is *visible*
/// once there is the question, and "it is not" is the answer the fix produces —
/// so those use `probePhase8` and the label sweep, which report absence instead
/// of failing on it.
extension Phase8AccessibilityUITests {
    // MARK: Leg 1 — the reviewer surface (08-02's original clause, unchanged)

    @MainActor
    func reviewerSurfaceViolations() -> [String] {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)
        guard openSettingsHub(app) else { return [] }

        let advanced = app.scrollToPhase8("settings.hub.advanced")
        guard advanced.exists else { return [] }
        advanced.tap()

        var violations: [String] = []
        // 08-06 — `probePhase8`, not `scrollToPhase8`: this clause asks whether
        // the reviewer surface is still reachable, and "it is not" is now the
        // answer. The precondition form asserted the row into existence, so
        // deleting the row turned this RED into a harness failure that said
        // nothing about the support boundary it exists to measure.
        if let review = app.probePhase8("settings.advanced.loincReviewRow") {
            violations.append("a clinical reviewer surface is one tap from Settings for every consumer")
            review.tap()
            let gated = app.alerts.firstMatch.waitForExistence(timeout: 3)
                || app.sheets.firstMatch.waitForExistence(timeout: 1)
            if !gated {
                violations.append("it opened directly, with no deliberate support session in front of it")
            }
        }
        return violations
    }

    // MARK: Leg 2 — notification diagnostics

    /// Settings → Notifications → Advanced diagnostics. The instruments are the
    /// two `diagnosticsRespectConsumerBoundary` enumerates for this surface —
    /// the device-token fragments and the forced re-registration — plus the raw
    /// banner-category identifiers the plan gates alongside them.
    @MainActor
    func notificationDiagnosticsViolations() -> [String] {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)
        guard openSettingsHub(app) else { return [] }

        let notifications = app.scrollToPhase8("settings.hub.notifications")
        guard notifications.exists else { return [] }
        notifications.tap()
        dismissFixtureAlert(app)

        // `NotificationsScreen` builds twelve lazy cards and the diagnostics
        // entry is the eleventh, so the default eight swipes stop short of it.
        let entry = app.scrollToPhase8("notifications.diagnostics.entry", swipes: 25)
        guard entry.exists else { return [] }
        entry.tap()

        var violations: [String] = []
        guard app.awaitPhase8(app.phase8Element("meds.diagnostics.authStatus"), "the notification diagnostics page") else { return violations }

        // One downward pass, no rewinds: the diagnostics page renders the
        // registration audit above the categories above the support entry, so
        // every probe below continues where the previous one stopped. Rewinding
        // between them doubled the swipe count for nothing, and swipe volume on
        // a lazily-built settings page is the expensive part of this case.
        // The gate simulator runs in German, so both catalogue values are named.
        if let registration = probeText(app, ["APNs registration", "APNs-Registrierung"]) {
            violations.append("the APNs registration audit is listed for every consumer (\(registration))")
        }
        if let banner = probeText(app, ["Buttons on the banner", "Knöpfe am Banner"]) {
            violations.append("the registered banner categories are listed for every consumer (\(banner))")
        }
        for instrument in Self.notificationInstruments where app.phase8Element(instrument.id).exists {
            violations.append("\(instrument.what) is visible with no support session in front of it")
        }

        violations += supportGateViolations(
            app,
            named: "the notification support detail",
            entry: "notif.supportDiagnostics.entry",
            deep: Self.notificationInstruments
        )
        return violations
    }

    // MARK: Leg 3 — Apple-Health diagnostics

    /// Settings → Integrations → Apple Health → Sync diagnostics. The instrument
    /// is the wake-channel card `diagnosticsRespectConsumerBoundary` names, plus
    /// the raw-heart-rate switch this plan deleted outright — a control that has
    /// no confirmed state either, because it has no state at all any more.
    @MainActor
    func appleHealthDiagnosticsViolations() -> [String] {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)
        guard openSettingsHub(app) else { return [] }

        let integrations = app.scrollToPhase8("settings.hub.integrations")
        guard integrations.exists else { return [] }
        integrations.tap()

        let appleHealth = app.scrollToPhase8("settings.integrations.appleHealthRow", swipes: 20)
        guard appleHealth.exists else { return [] }
        appleHealth.tap()
        dismissFixtureAlert(app)

        let diagnostics = app.scrollToPhase8("settings.integrations.hkDiagnosticsRow", swipes: 20)
        guard diagnostics.exists else { return [] }
        diagnostics.tap()
        dismissFixtureAlert(app)

        var violations: [String] = []
        if let wakes = probeText(app, ["Background wakes", "Hintergrund-Wecks"]) {
            violations.append("the background wake counters are visible for every consumer (\(wakes))")
        }
        if probeText(app, ["Pulse upload", "Puls-Übertragung"]) != nil {
            violations.append("a release Settings page can still switch this device to raw heart-rate upload")
        }

        violations += supportGateViolations(
            app,
            named: "the Apple-Health support detail",
            entry: "settings.hkdiag.supportDiagnosticsEntry",
            deep: Self.wakeInstruments
        )
        return violations
    }

    // MARK: The gate itself

    /// Opens the support entry on whatever diagnostics page is showing and
    /// checks both halves of the claim: nothing deep is composed before the
    /// second confirmation step, and the second step actually opens it. A gate
    /// that hides the detail forever is not a gate, it is a deletion with extra
    /// steps — and this plan deletes the one thing that deserved deleting.
    @MainActor
    private func supportGateViolations(
        _ app: XCUIApplication,
        named surface: String,
        entry identifier: String,
        deep instruments: [(id: String, what: String)]
    ) -> [String] {
        var violations: [String] = []
        guard let entry = app.probePhase8(identifier, swipes: 20) else {
            violations.append("\(surface) has no support entry at all, so the detail is unreachable")
            return violations
        }
        entry.tap()

        guard app.awaitPhase8(
            app.phase8Element("settings.supportDiagnostics.start"),
            "the locked support session on \(surface)"
        ) else { return violations }

        // Locked: the detail must not be anywhere on the page, so this looks
        // through the whole scroll view rather than only at what is on screen.
        for instrument in instruments where app.probePhase8(instrument.id, swipes: 3) != nil {
            violations.append("\(instrument.what) is composed on \(surface) before anything was confirmed")
        }
        scrollToTop(app)

        app.phase8Element("settings.supportDiagnostics.start").tap()
        guard app.phase8Element("settings.supportDiagnostics.confirm").waitForExistence(timeout: 5) else {
            violations.append("\(surface) unlocked in one tap, with no consequence stated in between")
            return violations
        }
        for instrument in instruments where app.probePhase8(instrument.id, swipes: 3) != nil {
            violations.append("\(instrument.what) is composed on \(surface) after only the first of two steps")
        }
        scrollToTop(app)

        app.phase8Element("settings.supportDiagnostics.confirm").tap()
        let opened = instruments.contains { app.probePhase8($0.id, swipes: 12) != nil }
        if !opened {
            violations.append("\(surface) showed nothing after a confirmed session, so the gate hides rather than gates")
        }
        return violations
    }

    // MARK: Reading a lazy page

    /// A bounded scroll-and-look for a rendered label, in either catalogue
    /// language, without asserting.
    ///
    /// The first shape of this helper collected `staticTexts.allElementsBoundByIndex`
    /// after every swipe. It was correct and it cost **five minutes** on one
    /// page — a full hierarchy dump per swipe on a twelve-card settings screen —
    /// which is how the second UI gate ran out of wall clock rather than out of
    /// assertions. One indexed query per candidate per swipe answers the same
    /// question in seconds.
    @MainActor
    private func probeText(_ app: XCUIApplication, _ candidates: [String], swipes: Int = 6) -> String? {
        for _ in 0 ..< swipes {
            for candidate in candidates where app.staticTexts[candidate].exists {
                return candidate
            }
            app.swipeUp()
        }
        for candidate in candidates where app.staticTexts[candidate].exists {
            return candidate
        }
        return nil
    }

    /// The hermetic fixture serves no notification-settings or Apple-Health
    /// summary endpoint, so those screens raise their generic load-error alert
    /// on arrival. That is a fixture gap, not a product claim — but a presented
    /// alert swallows every swipe underneath it, which is why the first run of
    /// this leg reported "the diagnostics entry never scrolled into view" while
    /// the label sweep clearly showed the page. Dismissed before anything is
    /// measured; every card these legs read is static and needs no load.
    @MainActor
    private func dismissFixtureAlert(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        let confirm = alert.buttons["OK"]
        if confirm.exists {
            confirm.tap()
        } else {
            alert.buttons.firstMatch.tap()
        }
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0 ..< 6 {
            app.swipeDown()
        }
    }

    static var notificationInstruments: [(id: String, what: String)] {
        [
            (id: "notif.diagnostics.tokenPrefix", what: "the device-token prefix"),
            (id: "notif.diagnostics.tokenSuffix", what: "the device-token suffix"),
            (id: "notif.diagnostics.forceFresh", what: "the forced APNs re-registration")
        ]
    }

    static var wakeInstruments: [(id: String, what: String)] {
        [
            (id: "settings.supportDiagnostics.wakeObserver", what: "the background-observer wake timestamp"),
            (id: "settings.supportDiagnostics.wakeProcessing", what: "the BGProcessing wake timestamp")
        ]
    }
}
