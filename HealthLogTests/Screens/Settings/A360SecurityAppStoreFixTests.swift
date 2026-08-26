import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Regression guards for the A360-3 (security) + A360-6 (App Store) release
/// fixes. Several are source-level guards: the affected behaviour (clipboard
/// privacy options, an app-switcher cover frame, a screen subtitle string) is
/// not cheaply observable from a headless unit test, so we pin the source so a
/// drift back to the insecure / non-compliant shape breaks here.
@MainActor
@Suite("A360 security + App Store fixes")
struct A360SecurityAppStoreFixTests {
    /// Resolve the repo root from this test file's path so the source-level
    /// guards can read sibling app sources (the simulator shares the host FS).
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Screens
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - S-1 — app-switcher privacy cover

    @Test("PrivacyCoverView compiles + conforms to View")
    func privacyCoverCompiles() {
        let view: any View = PrivacyCoverView()
        _ = view
    }

    @Test("RootView gates the privacy cover on a non-active scene phase")
    func rootViewShowsCoverWhenNotActive() throws {
        let text = try source("HealthLog/App/RootView.swift")
        // The cover is driven UNCONDITIONALLY by `scenePhase != .active` so the
        // `.inactive` snapshot frame is covered — independent of the opt-in
        // biometric lock.
        #expect(text.contains("if scenePhase != .active {"))
        #expect(text.contains("PrivacyCoverView()"))
    }

    @Test("PrivacyCoverView reads no PHI — only the brand glyph + app name")
    func privacyCoverIsPhiFree() throws {
        let text = try source("HealthLog/App/PrivacyCoverView.swift")
        // The cover must not reach into any @Environment store (no PHI source).
        #expect(!text.contains("@Environment"))
        #expect(text.contains("HLColor.background"))
    }

    // MARK: - S-2 — share-link clipboard privacy

    @Test("ShareLinkTokenSheet copies via setItems with localOnly + 120s expiry")
    func shareLinkClipboardUsesPrivacyGuards() throws {
        let text = try source("HealthLog/Screens/Settings/Sub/ShareLinkTokenSheet.swift")
        // No bare `UIPasteboard.general.string = …` write may remain — those have
        // no expiry and are mirrored by Universal Clipboard.
        #expect(!text.contains("UIPasteboard.general.string ="))
        // Both guards present on the shared sensitive-copy helper.
        #expect(text.contains("UIPasteboard.general.setItems"))
        #expect(text.contains(".localOnly: true"))
        #expect(text.contains(".expirationDate: Date().addingTimeInterval(120)"))
    }

    // MARK: - S-4 — outbox file-protection failure is observable

    @Test("Outbox file-protection failure is logged, not silently swallowed")
    func outboxFileProtectionFailureIsObservable() throws {
        let text = try source("HealthLog/Repositories/OutboxStore.swift")
        // The `try?` that swallowed a protection-apply failure must be gone;
        // the failure now routes through the logger.
        #expect(!text.contains("try? applyFileProtection(to: storeURL)"))
        #expect(text.contains("try applyFileProtection(to: storeURL)"))
        #expect(text.contains("HLLog.outbox.error("))
    }

    // MARK: - R1 — FHIR / Doctor-Report disclaimer + wording

    @Test("HealthExportDisclaimerCard compiles + conforms to View")
    func disclaimerCardCompiles() {
        let view: any View = HealthExportDisclaimerCard()
        _ = view
    }

    @Test("FHIR export copy drops the 'Clinical-grade' over-claim")
    func fhirSubtitleIsNotClinicalGrade() throws {
        // 18-03 — `SettingsFHIRExportScreen` is gone; FHIR is one of four output
        // forms on the unified sharing surface. The claim did not move with the
        // file, it moved with the copy: the over-claim must not reappear
        // anywhere the user reads about the FHIR export, and the visible
        // disclaimer must still sit on the surface that hands the file over.
        let screen = try source("HealthLog/Screens/Sharing/UnifiedSharingScreen.swift")
        let copy = try source("HealthLog/Screens/Sharing/UnifiedSharingCopy.swift")
        let catalogue = try source("HealthLog/Resources/Localizable.xcstrings")
        #expect(!screen.contains("Clinical-grade"))
        #expect(!copy.contains("Clinical-grade"))
        #expect(!catalogue.contains("Clinical-grade"))
        #expect(!catalogue.contains("Klinisch standardisiert"))
        // Control: the catalogue really is the file we just searched.
        #expect(catalogue.contains("sharing.unified.form.fhir.body"))
        // The visible disclaimer card is surfaced on the sharing surface.
        #expect(screen.contains("HealthExportDisclaimerCard()"))
    }

    @Test("The surface that hands a report over surfaces the visible disclaimer card")
    func doctorReportSurfacesDisclaimer() throws {
        // 18-03 — `DoctorReportScreen` became the `pdf` output form of the one
        // sharing surface. The disclaimer belongs wherever a report leaves the
        // device, so the pin follows the report rather than the filename.
        let text = try source("HealthLog/Screens/Sharing/UnifiedSharingScreen.swift")
        #expect(text.contains("UnifiedSharingStore.OutputForm.allCases"), "control: the sharing surface was read")
        #expect(text.contains("HealthExportDisclaimerCard()"))
    }

    @Test("Disclaimer xcstrings keys exist + resolve in en")
    func disclaimerStringsResolve() {
        for key in [
            "export.disclaimer.not_certified",
            "appstore.disclaimer.card_title",
            "appstore.disclaimer.consult_doctor"
        ] {
            let value = String(localized: String.LocalizationValue(key))
            // A missing key returns the key itself verbatim.
            #expect(value != key, "Missing localization for \(key)")
        }
    }

    // MARK: - M1 — drop the "coming soon" forward-promise

    @Test("Medication delivery-scope hint drops the 'coming soon' forward-promise")
    func medScopeHintHasNoComingSoon() {
        let value = String(localized: "med.edit.scope.sync_pending")
        #expect(!value.lowercased().contains("coming soon"))
        #expect(!value.lowercased().contains("folgt"))
    }
}
