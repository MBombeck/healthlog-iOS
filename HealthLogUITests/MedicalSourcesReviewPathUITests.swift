import XCTest

/// **1.0.3 — the App Review 1.4.1 reviewer path, photographed.**
///
/// Apple rejected 1.0 under guideline 1.4.1 ("medical information without
/// citations"). 1.0.3 answers with `HLSourcesLink` controls, `HLSourcesSheet`
/// and the `MedicalSourcesScreen` hub, reachable from More → Health & care,
/// Settings → About → Links, and the first-launch disclaimer sheet. The
/// Resolution Center reply needs to SHOW that, in both shipped languages, so
/// this class walks the reviewer's own path hermetically and attaches an
/// `XCTAttachment(screenshot:)` at every citation surface it reaches.
///
/// **Every numbered surface is an assertion.** The first pass could only reach
/// the hub and the disclaimer, because the surfaces Apple's rejection is
/// actually about — a correlation card, a classified blood-pressure reading, a
/// lab biomarker, a questionnaire result — need the account to HOLD something,
/// and the shared hermetic table serves `[]` for all four. `-uitest-citations`
/// (`HermeticFixtures+Citations`) puts real data behind each of them, so an
/// absent citation control is now a defect and this class goes red for it.
///
/// Every shot is also mirrored to `evidenceRoot` on the host filesystem, so the
/// evidence survives a result-bundle export that goes wrong. Not a release
/// gate: see `scripts/release-ui-tests.json`.
@MainActor
final class MedicalSourcesReviewPathUITests: XCTestCase {
    /// The two languages HealthLog ships. Forced per launch with
    /// `-AppleLanguages` / `-AppleLocale`, exactly like the marketing captures,
    /// so one simulator produces both evidence sets.
    private enum Language: String {
        case en
        case de

        var locale: String {
            switch self {
            case .en: "en_US"
            case .de: "de_DE"
            }
        }
    }

    /// Where the PNGs land on the host. Renamed into
    /// the chosen local evidence directory.
    private static let evidenceRoot = "/tmp/hl-cite-evidence"

    private var language: Language = .en
    private var captured: [String] = []
    private var skipped: [String] = []

    /// Opens a capture run. Not `setUpWithError`: the XCTest hooks are
    /// `nonisolated`, and everything this class holds — the language, the two
    /// ledgers — is main-actor state the walk mutates.
    private func beginCapture(_ language: Language) {
        // A capture run must not stop at the first missing surface: the later
        // shots are independent evidence.
        continueAfterFailure = true
        self.language = language
        captured = []
        skipped = []
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.evidenceRoot),
            withIntermediateDirectories: true
        )
    }

    /// Closes a capture run with the ledger of what it did and did not reach —
    /// the first thing to read in the result bundle.
    private func finishCapture() {
        let summary = """
        language: \(language.rawValue)
        captured (\(captured.count)):
        \(captured.map { "  - \($0)" }.joined(separator: "\n"))
        not captured (\(skipped.count)):
        \(skipped.map { "  - \($0)" }.joined(separator: "\n"))
        """
        let note = XCTAttachment(string: summary)
        note.name = "\(language.rawValue)-capture-manifest"
        note.lifetime = .keepAlways
        add(note)
    }

    // MARK: - Cases

    func testReviewerPath_en() {
        walkReviewerPath(.en)
    }

    func testReviewerPath_de() {
        walkReviewerPath(.de)
    }

    /// The first screen a reviewer sees on a fresh install. A hermetic boot
    /// normally cannot reach it: the `/api/auth/me` fixture stamps
    /// `disclaimerAcknowledgedAt`, and `launchHermeticAndWaitForDashboard` adds
    /// `-uitest-ack-disclaimer` on top. `-uitest-disclaimer-unacked` is the
    /// inverse seam in `DisclaimerAckStore` — it forces the resolved state to
    /// NOT acknowledged, so `RootView`'s gate renders
    /// `MedicalDisclaimerAckSheet` in front of the shell. The launch below
    /// therefore does NOT use the shared helper.
    func testDisclaimerSheetPointer_en() {
        walkDisclaimerSheet(.en)
    }

    func testDisclaimerSheetPointer_de() {
        walkDisclaimerSheet(.de)
    }

    private func walkDisclaimerSheet(_ language: Language) {
        beginCapture(language)
        defer { finishCapture() }
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language.rawValue))",
            "-AppleLocale", language.locale,
            "-uitest-hermetic",
            "-uitest-disable-biometric-lock",
            "-uitest-disclaimer-unacked"
        ]
        app.launch()

        let pointer = firstElement(app, "disclaimer.ack.sourcesLink")
        XCTAssertTrue(
            pointer.waitForExistence(timeout: 60),
            "The first-launch disclaimer sheet did not present its medical-sources pointer"
        )
        // The pointer sits below three copy sections; scroll it into frame so
        // the evidence shot actually shows it.
        for _ in 0 ..< 6 where !pointer.isHittable {
            app.swipeUp()
            settle(0.5)
        }
        capture(app, "00-disclaimer-sheet")

        // The pointer must actually land on the hub — a dead link on the
        // reviewer's first screen would be worse than no link.
        pointer.tap()
        XCTAssertTrue(
            firstElement(app, "sources.hub").waitForExistence(timeout: 20),
            "The disclaimer sheet's sources pointer did not open the Medical sources hub"
        )
        capture(app, "00b-disclaimer-sheet-hub")
    }

    // MARK: - The walk

    private func walkReviewerPath(_ language: Language) {
        beginCapture(language)
        defer { finishCapture() }
        let app = boot(language)

        stepMoreTabToHub(app)
        stepSettingsAboutLink(app)
        stepInsightsCorrelations(app)
        stepBloodPressurePage(app)
        stepLabsBiomarker(app)
        stepMentalWellbeing(app)
    }

    /// 1 — More tab → the Medical sources row → the hub → first methodology
    /// disclosure expanded. Hard assertions: none of this depends on data.
    private func stepMoreTabToHub(_ app: XCUIApplication) {
        openMoreTab(app)
        let row = app.scrollToPhase8("more.row.medical_sources")
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "More → Health & care carries no Medical sources row"
        )
        // The Health & care list is long enough that the row lands under the
        // floating tab bar; an evidence shot has to SHOW the row.
        nudgeIntoFrame(app, row)
        capture(app, "01-more-tab")
        row.tap()

        let hub = firstElement(app, "sources.hub")
        XCTAssertTrue(
            hub.waitForExistence(timeout: 20),
            "The Medical sources row did not open the hub"
        )
        settle(1)
        capture(app, "02-hub")

        // The first methodology paragraph in `MedicalSourceCatalog.allMethodologyKeys`.
        let disclosure = firstElement(app, "sources.hub.method.sources.method.correlations")
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 10),
            "The hub's methods card carries no correlations methodology disclosure"
        )
        disclosure.tap()
        settle(1)
        capture(app, "03-hub-method-expanded")
    }

    /// 2 — More → gear → Settings hub → About → the Links card's hub entry.
    private func stepSettingsAboutLink(_ app: XCUIApplication) {
        popToRoot(app)
        openMoreTab(app)
        let gear = firstElement(app, "more.toolbar.gear")
        guard gear.waitForExistence(timeout: 15) else {
            XCTFail("The More header carries no Settings gear")
            return
        }
        gear.tap()

        let about = app.scrollToPhase8("settings.hub.about")
        XCTAssertTrue(about.waitForExistence(timeout: 15), "The Settings hub carries no About row")
        about.tap()

        let link = app.scrollToPhase8("settings.about.medicalSourcesLink")
        XCTAssertTrue(
            link.waitForExistence(timeout: 15),
            "Settings → About → Links carries no Medical sources entry"
        )
        settle(1)
        capture(app, "04-about-links")
    }

    /// 3 — Insights → "Relationships in your data" → a card's Sources control →
    /// the correlations sources sheet. Hard assertions: the citation overlay
    /// serves two FDR-surviving pairs, so the card MUST be there.
    private func stepInsightsCorrelations(_ app: XCUIApplication) {
        popToRoot(app)
        let insights = app.phase8Tab("sparkles")
        guard insights.waitForExistence(timeout: 20) else {
            XCTFail("The Insights tab is not reachable")
            return
        }
        insights.tap()
        settle(4)

        guard let disclosure = require(
            app,
            "insights.correlations.discovery.disclosure",
            "the 'Relationships in your data' block",
            swipes: 14
        ) else { return }
        disclosure.tap()
        settle(2)

        guard let link = require(
            app,
            "sources.correlations",
            "a correlation card's Sources control",
            swipes: 8
        ) else { return }
        nudgeIntoFrame(app, link)
        capture(app, "05-insights-correlations-card")
        link.tap()

        let sheet = firstElement(app, "sources.sheet.correlations")
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 15),
            "The correlation Sources control did not present sources.sheet.correlations"
        )
        settle(1)
        capture(app, "06-sources-sheet-correlations")
        dismissSheet(app)
    }

    /// 4 — the blood-pressure page's tappable "ESH 2023" classification caption
    /// and its sheet. The overlay's digest classifies the 30-day series as
    /// high-normal, which is what makes the caption mount.
    private func stepBloodPressurePage(_ app: XCUIApplication) {
        openDeepLink("healthlog://insights/blood-pressure")
        settle(6)
        // A deep-link jump can settle a page short (the first run landed with the
        // overview still 804pt off-screen). Align by frame before asserting.
        // The deep-link SLUG is `blood-pressure`, but the page identifier is
        // `insights.page.<MetricKind.rawValue>` — `MarketingScreenshotsTest`
        // aligns on the slug form, which matches nothing and silently no-ops.
        alignInsightsPage(app, "insights.page.bloodPressure")

        guard let caption = require(
            app,
            "sources.bpClassification",
            "the ESH 2023 classification caption",
            swipes: 10
        ) else { return }
        nudgeIntoFrame(app, caption)
        capture(app, "07-bp-page-esh-caption")
        caption.tap()

        let sheet = firstElement(app, "sources.sheet.bpClassification")
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 15),
            "The ESH caption did not present sources.sheet.bpClassification"
        )
        settle(1)
        capture(app, "08-sources-sheet-bp")
        dismissSheet(app)
    }

    /// 5 — More → Labs → the hs-CRP biomarker → its citation. The overlay
    /// serves one catalogue-linked marker with one in-range reading, and the
    /// name resolves through `BiomarkerExplainer` to the `hs-crp` slug — which
    /// is what gives the page the explainer paragraph the citation lives in.
    private func stepLabsBiomarker(_ app: XCUIApplication) {
        popToRoot(app)
        openMoreTab(app)
        guard let labs = require(app, "more.row.labs", "the Labs row on More", swipes: 12) else { return }
        labs.tap()
        settle(3)

        // The labs module is user-switchable; on a sim where it reads as
        // opt-in-pending the screen offers an Enable CTA instead of the list.
        let enable = firstElement(app, "labs.optIn.enable")
        if enable.waitForExistence(timeout: 3), enable.isHittable {
            enable.tap()
            settle(4)
        }

        guard let row = require(app, "labs.byType.item", "an hs-CRP row in the Labs by-type index", swipes: 8) else { return }
        row.tap()
        settle(3)

        guard let link = require(app, "sources.lab.hs-crp", "the hs-CRP citation control", swipes: 10) else { return }
        nudgeIntoFrame(app, link)
        capture(app, "09-labs-biomarker-sources")
    }

    /// 6 — More → Mental wellbeing → a completed PHQ-9 → the screening
    /// disclaimer on the result. The walk takes the questionnaire; the overlay
    /// answers the submit with a server-authoritative result (total 7, mild), so
    /// the result phase renders.
    private func stepMentalWellbeing(_ app: XCUIApplication) {
        popToRoot(app)
        openMoreTab(app)
        guard let row = require(app, "more.row.mental_wellbeing", "the Mental wellbeing row", swipes: 12) else { return }
        row.tap()
        settle(3)

        guard let start = probeByPrefix(app, prefix: "mentalHealth.choose.", swipes: 8) else {
            XCTFail("The Mental wellbeing screen offered no questionnaire to start")
            return
        }
        start.tap()
        settle(2)

        if firstElement(app, "mentalHealth.form.disclaimer").waitForExistence(timeout: 6) {
            capture(app, "10a-mental-health-form-disclaimer")
        }

        answerQuestionnaire(app)

        let submit = firstElement(app, "mentalHealth.submit")
        guard submit.waitForExistence(timeout: 10), submit.isHittable else {
            XCTFail("The questionnaire never reached a submittable state")
            return
        }
        submit.tap()
        settle(4)

        let disclaimer = firstElement(app, "mentalHealth.result.disclaimer")
        XCTAssertTrue(
            disclaimer.waitForExistence(timeout: 20),
            "The submitted PHQ-9 produced no result, so its screening disclaimer never rendered"
        )
        settle(1)
        capture(app, "10-mental-health-result-disclaimer")

        // The result's own citation control, beside the disclaimer.
        if let link = probeByPrefix(app, prefix: "sources.mentalHealth.", swipes: 6) {
            nudgeIntoFrame(app, link)
            link.tap()
            captureSourcesSheetByPrefix(
                app,
                prefix: "sources.sheet.mentalHealth.",
                shot: "10b-sources-sheet-mental-health"
            )
        }
    }

    /// Walks the one-question-per-step form, choosing the lowest option each
    /// time — the form auto-advances on selection — then the optional
    /// functional-difficulty step. Bounded by the longest instrument.
    private func answerQuestionnaire(_ app: XCUIApplication) {
        for index in 0 ..< 20 {
            let option = firstElement(app, "mentalHealth.item.\(index).option.0")
            guard option.waitForExistence(timeout: 4), option.isHittable else { break }
            option.tap()
            settle(0.6)
        }
        let functional = firstElement(app, "mentalHealth.functional.option.0")
        if functional.waitForExistence(timeout: 4), functional.isHittable {
            functional.tap()
            settle(1)
        }
    }
}

/// Boot, navigation and capture plumbing. Split into an extension so the
/// class body stays inside the project's `type_body_length` budget; the walk
/// itself reads as one sequence above.
@MainActor
extension MedicalSourcesReviewPathUITests {
    // MARK: - Boot

    private func boot(_ language: Language) -> XCUIApplication {
        let app = XCUIApplication()
        let greeting = app.launchHermeticAndWaitForDashboard(
            extraArguments: [
                "-AppleLanguages", "(\(language.rawValue))",
                "-AppleLocale", language.locale,
                // 1.0.3 (1.4.1) — the citation-evidence fixture overlay
                // (`HermeticFixtures+Citations`). Without it the correlation
                // card, the classified blood pressure, the lab biomarker and the
                // questionnaire result do not exist, and four of the six
                // citation controls Apple asked about cannot be photographed.
                "-uitest-citations",
                // Keeps the "Connect Apple Health" banner — and the modal system
                // HealthKit sheet a stray tap on it raises — off every shot.
                // Same argument-domain seam `MarketingScreenshotsTest` uses.
                "-hl.healthkit.requestedAt.hermetic-user", "true",
                "-hl.healthkit.workoutReadMigrated.hermetic-user", "true"
            ],
            timeout: 120
        )
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 120),
            "Hermetic boot did not reach the Dashboard"
        )
        dismissAIConsentSheet(app)
        return app
    }

    // MARK: - Navigation helpers

    private func openMoreTab(_ app: XCUIApplication) {
        let more = app.phase8Tab("ellipsis")
        guard more.waitForExistence(timeout: 20) else {
            XCTFail("The More tab is not reachable")
            return
        }
        more.tap()
        settle(2)
    }

    /// Walks back out of whatever navigation stack the previous step pushed, so
    /// each step starts from the tab root.
    private func popToRoot(_ app: XCUIApplication) {
        for _ in 0 ..< 6 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { return }
            back.tap()
            settle(1)
        }
    }

    /// Scrolls just far enough that `element` sits in the readable middle of
    /// the screen rather than behind the floating tab bar. A measured drag, not
    /// a `swipeUp()`: a full swipe would carry the row off the other edge.
    private func nudgeIntoFrame(_ app: XCUIApplication, _ element: XCUIElement) {
        guard element.exists else { return }
        let height = app.frame.height
        guard element.frame.midY > height * 0.7 else { return }
        let delta = min(element.frame.midY - height * 0.45, height * 0.3)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -delta)))
        settle(1)
    }

    /// Pages the Insights pager horizontally until `identifier`'s page sits at
    /// the viewport origin. Bounded; a page that never appears simply leaves the
    /// caller's own assertion to report it.
    private func alignInsightsPage(_ app: XCUIApplication, _ identifier: String) {
        let page = app.scrollViews.matching(identifier: identifier).firstMatch
        for _ in 0 ..< 14 {
            guard page.exists else { break }
            let minX = page.frame.minX
            if abs(minX) < 50 { break }
            if minX > 0 { app.swipeLeft() } else { app.swipeRight() }
            settle(1)
        }
        settle(2)
    }

    private func openDeepLink(_ string: String) {
        guard let url = URL(string: string) else { return }
        XCUIDevice.shared.system.open(url)
    }

    /// `HLSourcesSheet` presents as a form sheet with no explicit close control,
    /// so it is dismissed the way a user dismisses it: a drag down from the top
    /// of the sheet.
    private func dismissSheet(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        settle(2)
    }

    /// Resolves the auto-presented AI-consent gate — by ACCEPTING it. Declining
    /// is not harmless: `InsightsStore.load()` is gated on that consent, the
    /// comprehensive digest builds the blood-pressure status card, and the ESH
    /// 2023 caption lives on that card. A reviewer walking citations accepts.
    private func dismissAIConsentSheet(_ app: XCUIApplication) {
        for label in ["Accept", "Akzeptieren"] {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                settle(1)
                return
            }
        }
    }

    /// Scrolls to a REQUIRED element and fails with a sentence naming what was
    /// expected when it never arrives. The probe/assert split from B2 is gone
    /// for these six steps: the citation overlay puts real data behind every one
    /// of them, so an absent control is now a defect, not a fixture gap.
    private func require(_ app: XCUIApplication, _ identifier: String, _ what: String, swipes: Int) -> XCUIElement? {
        let element = firstElement(app, identifier)
        for _ in 0 ..< swipes {
            if element.exists, element.isHittable { return element }
            app.swipeUp()
            settle(0.5)
        }
        if element.exists { return element }
        XCTFail("Missing \(what) (\(identifier))")
        attachFailureDiagnostics(app: app, label: "\(language.rawValue)-\(identifier)")
        return nil
    }

    /// An element by identifier, always as `firstMatch`. The citation controls
    /// are deliberately NOT unique — `sources.correlations` rides every
    /// correlation card AND the block footer — and XCTest's single-element
    /// subscript raises "Multiple matching elements found" on exactly those.
    private func firstElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// `probePhase8`, but for the identifier FAMILIES whose tail is a runtime
    /// slug (`sources.lab.<slug>`, `sources.sheet.lab.<slug>`).
    private func probeByPrefix(_ app: XCUIApplication, prefix: String, swipes: Int) -> XCUIElement? {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        for _ in 0 ..< swipes {
            if element.exists, element.isHittable { return element }
            app.swipeUp()
            settle(0.5)
        }
        return element.exists ? element : nil
    }

    private func captureSourcesSheetByPrefix(_ app: XCUIApplication, prefix: String, shot: String) {
        settle(2)
        let sheet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        if sheet.exists {
            capture(app, shot)
            dismissSheet(app)
        } else {
            note("\(shot) — the citation control did not present a sheet under \(prefix)")
        }
    }

    // MARK: - Capture primitives

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Attaches the screen as `<lang>-<NN-name>` — the evidence filename the
    /// Resolution Center reply cites — and mirrors it onto the host filesystem.
    private func capture(_ app: XCUIApplication, _ name: String) {
        dismissAIConsentSheet(app)
        let shot = XCUIScreen.main.screenshot()
        let filename = "\(language.rawValue)-\(name)"
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        captured.append(filename)

        let url = URL(fileURLWithPath: Self.evidenceRoot).appendingPathComponent("\(filename).png")
        do {
            try shot.pngRepresentation.write(to: url)
        } catch {
            note("\(filename) — could not be mirrored to the host: \(error)")
        }
    }

    /// Records something worth knowing that is not a failure — a host-mirror
    /// write that did not land, or an optional extra shot the walk skipped. The
    /// six numbered citation surfaces are assertions now, not notes.
    private func note(_ reason: String) {
        skipped.append(reason)
        let attachment = XCTAttachment(string: reason)
        attachment.name = "\(language.rawValue)-skip-note"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
