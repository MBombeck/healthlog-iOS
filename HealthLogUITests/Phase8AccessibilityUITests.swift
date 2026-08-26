import XCTest

/// **Phase 08 Wave 0 — the release surfaces and the native audit, hermetically.**
///
/// Every case boots through `-uitest-hermetic` + `-uitest-phase8`, so no login,
/// no network and no real HealthKit, APNs or credential is involved. Each test
/// reaches its screen through `awaitPhase8`, which fails loudly and separately
/// when a precondition never arrives — the behavioural-RED harness rejects that
/// as infrastructure, so a Phase-8 marker can only ever be produced by the
/// product assertion it names.
final class Phase8AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: RED — medication has one presentation

    /// Cards-only is a product decision, and the layout sheet is where a user
    /// meets the choice it removes. The picker still offers two segments.
    @MainActor
    func testMedicationIsCardsOnly() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)

        app.phase8Tab("pills.fill").tap()
        let customize = app.phase8Element("medications.header.customizeButton")
        guard app.awaitPhase8(customize, "the medications customise button") else { return }
        customize.tap()

        var violations: [String] = []
        let picker = app.segmentedControls["medications.customize.viewPicker"]
        if picker.waitForExistence(timeout: 10) {
            violations.append("the layout sheet still offers \(picker.buttons.count) list presentations")
        }
        // The gate's simulator runs in German, so both catalogue values of
        // `med.layout.view.table` are named.
        for table in ["Table", "Tabelle"] where app.buttons[table].exists || app.staticTexts[table].exists {
            violations.append("the table presentation is still an offered choice (\(table))")
        }
        record(violations, for: "medication-cards-only")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI medication table choice remained visible"
        )
    }

    // MARK: RED — About states the build it actually is

    /// `SettingsAboutScreen` composes its marketing version by subtracting 40
    /// from the build number and then claims, with no check of any kind, that
    /// the installed version is current. Both are readable from the screen: a
    /// version whose patch component is exactly `build − 40` was computed, not
    /// read, and the currency claim is a literal.
    @MainActor
    func testAboutExposesVersionAndBuild() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)
        guard openSettingsHub(app) else { return }

        let about = app.scrollToPhase8("settings.hub.about")
        guard about.exists else { return }
        about.tap()
        // "Version" and "Build" are the two literal `statRow` labels on the
        // identity card — the screen's own words, and the only landmark this
        // test needs.
        guard app.awaitPhase8(app.staticTexts["Version"], "the About identity card") else { return }

        var labels = Set(app.staticTexts.allElementsBoundByIndex.map(\.label))
        app.swipeUp()
        labels.formUnion(app.staticTexts.allElementsBoundByIndex.map(\.label))
        print("PHASE8-DIAGNOSTIC about labels: \(labels.sorted())")

        let version = labels.first { $0.range(of: "^[0-9]+(\\.[0-9]+)+$", options: .regularExpression) != nil }
        let build = labels.first { $0.range(of: "^[0-9]+$", options: .regularExpression) != nil }

        var violations: [String] = []
        if let version, let build, let buildNumber = Int(build) {
            let components = version.split(separator: ".")
            if components.count > 3 {
                violations
                    .append("the displayed version \(version) has \(components.count) segments; a marketing version has at most three")
            }
            if let patch = Int(components.last ?? ""), patch == max(0, buildNumber - 40) {
                violations.append("the displayed version \(version) is composed from build \(build), not read from it")
            }
        } else {
            violations.append("About did not display a version and a build as separate readable values")
        }
        for claim in ["Current version installed.", "Aktuelle Version installiert"]
            where labels.contains(where: { $0.hasPrefix(claim.replacingOccurrences(of: ".", with: "")) })
        {
            violations.append("About claims the installed version is current without checking anything")
        }
        record(violations, for: "about")
        XCTAssertTrue(violations.isEmpty, "EXPECTED_RED: 08-02 UI About omitted exact version or build")
    }

    // MARK: RED — operator tools need a deliberate session

    /// The clinical review registry — an operator/reviewer surface whose whole
    /// purpose is to attribute a sign-off — sits one tap below Settings for
    /// every consumer, and opens with no confirmation of any kind.
    ///
    /// **08-15 — the case now walks the surfaces its name always claimed.**
    /// Until this plan its only probe was the LOINC reviewer row, so when 08-06
    /// deleted that row the case went green while
    /// `Phase8ReleaseSurfaceTests.diagnosticsRespectConsumerBoundary` was still
    /// red on three counts — a passing test certifying that a deleted screen
    /// was still deleted. The reviewer clause below is unchanged; two legs were
    /// added that actually open the notification and Apple-Health diagnostics
    /// screens and look for the engineering instruments the unit RED enumerates.
    @MainActor
    func testSupportDiagnosticsRequireConfirmation() {
        var violations: [String] = []
        violations += reviewerSurfaceViolations()
        violations += notificationDiagnosticsViolations()
        violations += appleHealthDiagnosticsViolations()
        record(violations, for: "support-gate")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI deep diagnostics opened without confirmation"
        )
    }

    // MARK: RED — sign-out is destructive and must be confirmed

    /// `HLSettingsActionRow(presents: .confirm)` only means "paint no chevron";
    /// the confirmation, if any, belongs to the caller — and
    /// `SettingsAccountScreen` calls `authStore.logout()` straight from the tap.
    /// So there is nothing to cancel: the session is gone by the time the user
    /// could have changed their mind.
    @MainActor
    func testLogoutConfirmationPreservesSessionOnCancel() {
        let app = XCUIApplication()
        app.launchPhase8Shell(.releaseSurface)
        guard openSettingsHub(app) else { return }

        let account = app.phase8Element("settings.hub.account")
        guard app.awaitPhase8(account, "the Account row") else { return }
        account.tap()

        let signOut = app.scrollToPhase8("more.row.sign_out")
        guard signOut.exists else { return }
        signOut.tap()

        var violations: [String] = []
        let confirmed = app.alerts.firstMatch.waitForExistence(timeout: 4)
            || app.sheets.firstMatch.waitForExistence(timeout: 1)
        if !confirmed {
            violations.append("sign-out raised no confirmation, so there was nothing to cancel")
        }
        if app.phase8Element("onboarding.passwordLoginCTA").waitForExistence(timeout: 10) {
            violations.append("the session was already dropped before any confirmation could be answered")
        }
        // 08-09 — the cancel half this case is named after. Until this plan a
        // sign-out tap raised nothing, so there was no answer to give and the
        // two clauses above were the whole test. Now that a dialog exists, the
        // non-destructive answer has to leave the session standing — otherwise
        // the confirmation is a speed bump rather than a decision.
        violations += logoutCancelViolations(app, confirmationExists: confirmed)
        record(violations, for: "logout")
        XCTAssertTrue(
            violations.isEmpty,
            "EXPECTED_RED: 08-02 UI logout occurred before destructive confirmation"
        )
    }

    // MARK: RED — the native audit, at an accessibility text size

    /// The focused audit, run where the app is least adapted: the Dashboard and
    /// the medication list at the largest accessibility content size. Nothing in
    /// the app reads `dynamicTypeSize` on either surface, so this is the
    /// measurement the policy suite's descriptors predict.
    ///
    /// Issues are collected rather than reported, so the run produces exactly
    /// one named failure instead of one per finding — the harness requires the
    /// reason to appear exactly once.
    ///
    /// **This red is DECIDED, not open. Do not "fix" it.** The final-candidate
    /// UI review this case was deferred to (2026-08-16) was performed on
    /// 2026-08-25, before Phase 23 froze the submission candidate — a fix would
    /// have been a source change and `CANDIDATE-FREEZE.md` §8 restarts the
    /// freeze at a new build number on one. The operator **accepted and
    /// documented** two of the findings rather than fixing them:
    ///
    /// - **D-09-16-B** — `Dynamic Type font sizes are unsupported`
    ///   `[48#dashboard.profile.avatar-monogram @359,198 10x22]`, on 26 of 26
    ///   runs across both Dashboard states. Four removal routes were measured;
    ///   the best of them trades this one finding for two.
    /// - **D-09-16-C** — `Contrast failed [48#@80,625 268x464]`, the
    ///   `HealthKitConnectBanner` subtitle, on 13 of 13 banner-Dashboard runs.
    ///   At `AccessibilityXXXL` that is a 268×464 pt element on an 874 pt
    ///   screen. The one-line ink fix was written, measured and reverted
    ///   **twice** — it is the extent, not the colour.
    ///
    /// Both concern accessibility text sizes, not the default content size, and
    /// **no source change was made for either**. This case therefore keeps its
    /// `EXPECTED_RED: 08-02` marker and its `deferred-red` declaration in
    /// the release UI-test manifest, where the acceptances are recorded in
    /// full with their measurements and both dates. The banner *title*'s
    /// contrast finding (Liquid Glass, an app-wide `HLCard` decision) and
    /// D-12-12-A's banner-less pair were **not** covered by that decision and
    /// remain named open items in the submission handoff.
    @MainActor
    func testFocusedAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchPhase8Shell(
            .releaseSurface,
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )

        // **12-12 — the audit states which Dashboard it is auditing.**
        //
        // D-09-16-A: the HealthKit-connect banner was on the audited Dashboard
        // in one reading of ten, and the two screens it produces carry
        // *disjoint* finding sets — the banner pushes the medication-adherence
        // card past the audited fold and contributes two findings of its own in
        // its place. Until this precondition the audit reported on whichever
        // Dashboard it happened to get and never said which, so a finding
        // derived from one run could not be reproduced by the next.
        //
        // The banner is a single combined element: `.accessibilityElement(children:
        // .combine)` merges its two buttons into the identifier
        // `healthkitConnectBanner.connectButton-healthkitConnectBanner.dismissButton`,
        // so *neither* child identifier resolves and a wait on
        // `healthkitConnectBanner.connectButton` can only ever time out. Matching
        // the shared prefix is what actually addresses the surface.
        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "healthkitConnectBanner"))
            .firstMatch
        // Read once, before any wait. "Is the subject already decided when the
        // Dashboard greeting lands?" is the question that separates a race from
        // a leaked state, and a `waitForExistence` first would answer it by
        // construction. Recorded on every run so the answer stays re-measurable.
        print("PHASE8-AUDIT-SUBJECT immediate=\(banner.exists)")
        guard banner.waitForExistence(timeout: 20) else {
            attachFailureDiagnostics(app: app, label: "phase8-audit-subject")
            return XCTFail(
                "EXPECTED_RED: 12-12 focused audit did not get the HealthKit-banner Dashboard it audits"
            )
        }

        var findings: [String] = []
        try auditFocusedScreen(app, into: &findings, named: "dashboard")
        app.phase8Tab("pills.fill").tap()
        _ = app.phase8Element("medications.header.customizeButton").waitForExistence(timeout: 15)
        try auditFocusedScreen(app, into: &findings, named: "medications")

        record(findings, for: "focused-audit")
        if !findings.isEmpty {
            attachFailureDiagnostics(app: app, label: "phase8-audit")
        }
        XCTAssertTrue(
            findings.isEmpty,
            "EXPECTED_RED: 08-02 UI focused accessibility audit found a Phase 8 defect"
        )
    }

    // MARK: - Navigation

    /// More tab → the gear toolbar → the Settings hub, landing on its FIRST row.
    ///
    /// The hub builds sixteen lazy rows, so About and Privacy & Security are off
    /// the bottom of a freshly opened list and no amount of waiting produces
    /// them — the first gate run failed here three times for exactly that
    /// reason. Callers scroll to the row they want.
    @MainActor
    func openSettingsHub(_ app: XCUIApplication) -> Bool {
        app.phase8Tab("ellipsis").tap()
        let gear = app.phase8Element("more.toolbar.gear")
        guard app.awaitPhase8(gear, "the Settings gear on the More screen") else { return false }
        gear.tap()
        return app.awaitPhase8(app.phase8Element("settings.hub.account"), "the Settings hub")
    }

    /// Records what a RED actually found, so the gate log carries the evidence
    /// the single fixed marker cannot. Deliberately free of the marker string.
    func record(_ violations: [String], for test: String) {
        print("PHASE8-VIOLATIONS \(test): \(violations)")
    }

    /// Runs the native audit for the four types this phase owns and records the
    /// findings instead of failing on each one.
    @MainActor
    private func auditFocusedScreen(
        _ app: XCUIApplication,
        into findings: inout [String],
        named screen: String
    ) throws {
        var collected: [String] = []
        var detailed: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .dynamicType, .hitRegion, .textClipped]) { issue in
            // The system's own long form — measured contrast ratios, the font
            // that failed to scale. It names the element, so it goes into an
            // attachment on the result bundle rather than into the gate log,
            // which stays identifier-only.
            detailed.append(issue.detailedDescription)
            // 08-12 — the finding, and *which element* produced it. Until this
            // plan the log carried only `compactDescription`, so three dashboard
            // findings were reported for two years' worth of plans without ever
            // naming the view that had to change. Element type, identifier and
            // y-position only — never the label, because a label on either of
            // these screens carries a rendered health figure.
            let element = issue.element.map {
                let frame = $0.frame
                return "\($0.elementType.rawValue)#\($0.identifier)"
                    + "@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            }
            collected.append("\(screen): \(issue.compactDescription) [\(element ?? "no element")]")
            // Handled here so the audit does not raise its own failures; the
            // single named assertion above is the only reported one.
            return true
        }
        // The element tree of the screen that produced findings, captured while
        // that screen is still on top. The run-level diagnostics attach the tree
        // of whatever the app ended on, which for a Dashboard finding is the
        // wrong screen — that is why the Dashboard findings survived four plans
        // without anyone being able to name the views.
        if !collected.isEmpty {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(screen)-audit-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let details = XCTAttachment(string: detailed.joined(separator: "\n\n"))
            details.name = "\(screen)-audit-details"
            details.lifetime = .keepAlways
            add(details)
        }
        findings.append(contentsOf: collected)
    }
}
