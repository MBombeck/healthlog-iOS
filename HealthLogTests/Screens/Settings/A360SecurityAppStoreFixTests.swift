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

    // MARK: - App-switcher privacy cover

    @Test("PrivacyCoverView compiles + conforms to View")
    func privacyCoverCompiles() {
        let view: any View = PrivacyCoverView()
        _ = view
    }

    /// The shield is what the app switcher snapshots; reading any environment value
    /// beyond the colour scheme could paint health data into that frame.
    @Test("the root privacy shield reads no environment value but the colour scheme")
    func privacyShieldIsPhiFree() throws {
        let code = try source("HealthLog/App/RootPrivacyShield.swift")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let environmentReads = code.filter { $0.contains("@Environment") }
        #expect(environmentReads.count == 1)
        #expect(environmentReads.allSatisfy { $0.contains("@Environment(\\.colorScheme)") })
    }

    // MARK: - Share-link clipboard privacy

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

    // MARK: - FHIR / Doctor-Report disclaimer + wording

    @Test("HealthExportDisclaimerCard compiles + conforms to View")
    func disclaimerCardCompiles() {
        let view: any View = HealthExportDisclaimerCard()
        _ = view
    }

    @Test("FHIR export copy drops the 'Clinical-grade' over-claim")
    func fhirSubtitleIsNotClinicalGrade() throws {
        // `SettingsFHIRExportScreen` is gone; FHIR is one of four output
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
        // `DoctorReportScreen` became the `pdf` output form of the one
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

    // MARK: - Drop the "coming soon" forward-promise

    /// The medication footers must not promise features that are not there.
    @Test("Medication footers make no forward-promise")
    func medScopeHintHasNoComingSoon() {
        for key in ["med.edit.live_activity.footer", "med.edit.critical_alarm.footer"] {
            let value = String(localized: String.LocalizationValue(key)).lowercased()
            #expect(!value.contains("coming soon") && !value.contains("folgt"))
        }
    }
}
