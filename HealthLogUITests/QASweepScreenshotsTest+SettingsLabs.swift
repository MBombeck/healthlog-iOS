import UIKit
import XCTest

/// **iOS 1.4 B2-c — Settings, labs, records and the coach, photographed whole.**
///
/// The before-and-after pictures of the B2-c area: every Settings screen the
/// hub reaches (and the sub-screens behind them), the labs, documents and
/// records screens from More, the share screen and the coach sheet. Each screen
/// is shot from the top to its end, then its info sheet when the screen has one
/// (any navigation-bar button whose identifier ends in `.info`). Navigation is
/// soft like the rest of the sweep: a missing row is a line in `_notes.txt`.
/// Only runs when `HL_SWEEP_OUT` is set.
extension QASweepScreenshotsTest {
    func test_17a_settingsArea() {
        guard !isXXL else { return }
        boot()
        tab("ellipsis")
        guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { return }
        settle(2)
        walkToEnd("14-hub")
        visit("settings.hub.account", "14-account") {
            self.visit("settings.account.profileRow", "14-account-profile")
            self.visit("settings.account.sessionsRow", "14-account-sessions")
            self.visit("settings.account.securityRow", "14-account-security") {
                self.visit("settings.security.passkeysRow", "14-account-passkeys")
                self.visit("settings.security.twoFactorManageRow", "14-account-2fa")
            }
        }
        visit("settings.hub.dashboard", "14-appearance") {
            self.visit("settings.dashboard.customizeRow", "14-appearance-tiles")
            self.visit("settings.dashboard.insightsCustomizeRow", "14-appearance-insights")
        }
        visit("settings.hub.integrations", "14-integrations") {
            self.visit("settings.integrations.appleHealthRow", "14-applehealth") {
                self.visit("settings.integrations.appleHealthImportRow", "14-ahimport")
                self.visit("settings.integrations.healthAccessRow", "14-healthaccess")
                self.visit("settings.integrations.hkDiagnosticsRow", "14-syncdiag") {
                    self.visit("settings.hkdiag.supportDiagnosticsEntry", "14-syncdiag-support")
                }
            }
            self.visit("settings.integrations.withingsRow", "14-withings")
            self.visit("settings.integrations.whoopRow", "14-whoop")
        }
        for (row, name) in [
            ("devices", "14-devices"), ("siri", "14-siri"), ("mcp", "14-mcp"), ("apiTokens", "14-apitokens")
        ] {
            visit("settings.hub.\(row)", name)
        }
        visit("settings.hub.sources", "14-sources") {
            self.visit("settings.sources.priority.edit", "14-sources-editor")
        }
        visit("settings.hub.ai", "14-ai") {
            self.visit("SettingsAIScreen.coach.row", "14-coachsettings") {
                self.visit("settings.coach.conversationsRow", "14-coach-conversations")
                self.visit("settings.coach.memoryRow", "14-coach-memory")
                self.visit("settings.coach.aboutMeRow", "14-coach-aboutme")
            }
        }
        visit("settings.hub.serverSync", "14-server")
        visit("settings.hub.export", "14-export") {
            self.visit("settings.export.importRow", "14-export-import")
        }
        for (row, name) in [("healthScore", "14-healthscore"), ("modules", "14-modules"), ("advanced", "14-advanced")] {
            visit("settings.hub.\(row)", name)
        }
        visit("settings.hub.about", "14-about") {
            self.visit("settings.about.medicalSourcesLink", "14-medicalsources")
        }
    }

    func test_17b_recordsArea() {
        guard !isXXL else { return }
        boot(extra: ["-uitest-citations"])
        tab("ellipsis")
        visit("more.row.labs", "14-labs") {
            let first = self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs.byType.item'")).firstMatch
            if first.waitForExistence(timeout: 4), first.isHittable {
                first.tap()
                self.settle(3)
                self.walkToEnd("14-labs-biomarker")
                self.infoSheet("14-labs-biomarker", identifier: "biomarker.detail.info")
                self.goBack()
            } else {
                self.note("labs: no biomarker row")
            }
        }
        visit("more.row.documents", "14-documents")
        visit("more.row.about_me", "14-aboutme") {
            self.visit("aboutMe.row.anamnesis", "14-anamnesis")
            self.visit("aboutMe.injectionSitesRow", "14-injectionsites")
        }
        visit("more.row.allergies", "14-allergies")
        visit("more.row.family_history", "14-familyhistory")
        visit("more.row.measurements", "14-measurements") {
            self.visit("measurements.picker.customMetrics", "14-custommetrics")
        }
        scrollUpToTop()
        if tap(app.buttons["more.toolbar.share"], "share glyph") {
            settle(4)
            walkToEnd("14-share")
            infoSheet("14-share")
            visit("sharing.unified.manageLinks", "14-share-links")
            goBack()
        }
    }

    func test_17c_coach() {
        guard !isXXL else { return }
        boot()
        openDeepLink("healthlog://coach")
        settle(5)
        // The link lands on Insights before its sheet listens; the header's
        // sparkle opens the coach (or, without consent, its choice).
        for id in ["InsightsScreen.askCoachCollapsedCoin.header", "InsightsScreen.enableCoachCoin.header"] {
            let coin = app.buttons[id]
            if coin.waitForExistence(timeout: 3), coin.isHittable {
                coin.tap()
                settle(3)
                break
            }
        }
        walkToEnd("14-coach")
        dismissSheet()
    }

    /// **1.4 B4-b — the Dynamic Type pass.** Today and the Settings pages
    /// this unit reworked, at the large text sizes: by default XXL (the
    /// largest standard size) and AX-XXXL (the largest accessibility size),
    /// each a fresh launch, pictures prefixed `18-xxl-` and `18-ax5-`.
    /// `HL_SWEEP_DT_SIZES` (comma-separated content size category names)
    /// narrows the set. Runs only with `HL_SWEEP_DT=1`, so the area walks
    /// above do not pay for it.
    func test_18_dynamicTypeTodaySettings() {
        guard env["HL_SWEEP_DT"] == "1" else { return }
        let sizes = (env["HL_SWEEP_DT_SIZES"] ?? "UICTContentSizeCategoryXXL,UICTContentSizeCategoryAccessibilityXXXL")
            .split(separator: ",").map(String.init)
        for size in sizes {
            let tag = size.contains("Accessibility") ? "18-ax5" : "18-xxl"
            boot(extra: ["-UIPreferredContentSizeCategoryName", size])
            walkToEnd("\(tag)-today")
            tab("ellipsis")
            guard tap(app.buttons["more.toolbar.gear"], "settings gear") else { continue }
            settle(2)
            walkToEnd("\(tag)-hub")
            visit("settings.hub.account", "\(tag)-account")
            visit("settings.hub.dashboard", "\(tag)-appearance")
            visit("settings.hub.integrations", "\(tag)-integrations") {
                self.visit("settings.integrations.appleHealthRow", "\(tag)-applehealth") {
                    self.visit("settings.integrations.hkDiagnosticsRow", "\(tag)-syncdiag")
                }
                self.visit("settings.integrations.withingsRow", "\(tag)-withings")
            }
            visit("settings.hub.ai", "\(tag)-ai") {
                self.visit("SettingsAIScreen.coach.row", "\(tag)-coachsettings")
            }
            visit("settings.hub.export", "\(tag)-export")
            visit("settings.hub.about", "\(tag)-about")
            app.terminate()
        }
    }

    // MARK: - Walk primitives

    /// Opens the row `identifier` (scrolling to it), photographs the screen to
    /// its end and its info sheet, runs `then` on it, and goes back.
    private func visit(_ identifier: String, _ name: String, then: (() -> Void)? = nil) {
        scrollUpToTop()
        guard let row = deepProbe(identifier) else {
            note("row not present: \(identifier)")
            return
        }
        row.tap()
        settle(3)
        walkToEnd(name)
        infoSheet(name)
        if let then {
            then()
        }
        goBack()
        settle(1)
    }

    /// `scrollDown`, started in the page's left margin (outside any card).
    private func marginScroll() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 600, thenHoldForDuration: 0.3)
        settle(1.2)
    }

    /// Like `probe`, but far enough for the longest settings screens.
    private func deepProbe(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        for step in 0 ..< 16 {
            if target.exists, target.isHittable { return target }
            // A drag that starts on a large button (the assistant source
            // picker) does not scroll; every other try drags along the
            // page's left margin, outside the cards.
            if step.isMultiple(of: 2) {
                scrollDown()
            } else {
                marginScroll()
            }
        }
        return target.exists && target.isHittable ? target : nil
    }

    /// The screen from where it stands down to its end: one shot, then one per
    /// scroll until a scroll leaves the picture unchanged (at most sixteen).
    private func walkToEnd(_ name: String) {
        shot("\(name)-top")
        var previous = contentSignature()
        for step in 1 ... 16 {
            scrollDown()
            var current = contentSignature()
            if current == previous {
                // A drag that started on a large button did not scroll; one
                // drag along the margin decides whether this is really the end.
                marginScroll()
                current = contentSignature()
            }
            if current == previous { break }
            previous = current
            shot("\(name)-scroll\(step)")
        }
        scrollUpToTop()
    }

    /// The page between the bars, without the scroll indicator and the left
    /// margin: a whole-screen comparison never matched at the end of a page
    /// after a margin drag, so every walk ran its sixteen steps.
    private func contentSignature() -> Data? {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let width = Double(image.width)
        let height = Double(image.height)
        let band = CGRect(x: width * 0.06, y: height * 0.2, width: width * 0.84, height: height * 0.6)
        return image.cropping(to: band).flatMap { UIImage(cgImage: $0).pngData() }
    }

    /// The screen's (i), when it has one: the sheet's top and one scroll.
    private func infoSheet(_ name: String, identifier: String? = nil) {
        // A page with its title in the header (the biomarker) carries the (i)
        // there, outside the navigation bar.
        let info = identifier.map { app.buttons[$0] }
            ?? app.navigationBars.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.info'")).firstMatch
        guard info.waitForExistence(timeout: 2), info.isHittable else { return }
        info.tap()
        settle(2.5)
        shot("\(name)-info-top")
        scrollDown()
        shot("\(name)-info-scroll1")
        dismissSheet()
    }
}
