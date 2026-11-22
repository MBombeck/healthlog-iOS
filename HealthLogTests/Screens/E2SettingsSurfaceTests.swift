// App-target symbols (`HKReadinessStore`, the settings views); the SPM test
// build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// Settings, account and catalog after the E2 pass: one connection state
    /// on the Apple Health page, the step-up hint not in the error colour, the
    /// IK only in the German profile, and the catalog using one word per thing.
    @Suite("E2 settings surfaces")
    @MainActor
    struct E2SettingsSurfaceTests {
        typealias Status = HKReadinessStore.SurfaceStatus

        // MARK: - Apple Health: one state from both sources

        @Test("the server says connected but iOS would still ask: the card says Not connected")
        func unansweredSheetIsNotConnected() {
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.receiving, action: .connect) == .notConnected)
        }

        @Test("a granted connection stays Connected whatever the write-back state")
        func grantedStaysConnected() {
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.receiving, action: .none) == .receiving)
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.receiving, action: .reviewWriteAccess) == .receiving)
        }

        @Test("declined and checking pass through unchanged")
        func otherStatesPassThrough() {
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.declined, action: .openHealthApp) == .declined)
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.checking, action: .none) == .checking)
            #expect(AppleHealthIntegrationDetailScreen.shownStatus(.notConnected, action: .connect) == .notConnected)
        }

        @Test("sync and the history count appear only for a standing connection")
        func syncOnlyWhenConnected() {
            #expect(AppleHealthIntegrationDetailScreen.showsHistory(status: .receiving))
            for status in [Status.notConnected, .declined, .checking] {
                #expect(!AppleHealthIntegrationDetailScreen.showsHistory(status: status))
                #expect(!AppleHealthIntegrationDetailScreen.isConnected(status: status))
            }
        }

        // MARK: - Siri

        @Test("the Shortcuts row opens the Shortcuts app")
        func shortcutsRowOpensShortcuts() {
            #expect(SettingsSiriShortcutsScreen.shortcutsAppURL?.scheme == "shortcuts")
        }

        // MARK: - Step-up hint

        @Test("asking for proof reads secondary, a failure keeps the error colour")
        func stepUpHintIsNotAnError() {
            #expect(StepUpRetry.messageTint(for: StepUpRetry.requiredMessage) == HLText.secondary)
            #expect(StepUpRetry.messageTint(for: "Verification failed") == HLColor.statusBad)
        }

        // MARK: - Profile

        @Test("the insurer's IK is asked for only in the German profile")
        func insurerIKOnlyInGerman() {
            #expect(EditProfileScreen.showsInsurerIK(appLanguage: "de"))
            #expect(EditProfileScreen.showsInsurerIK(appLanguage: "de-DE"))
            #expect(!EditProfileScreen.showsInsurerIK(appLanguage: "en"))
            #expect(!EditProfileScreen.showsInsurerIK(appLanguage: "nl"))
            #expect(!EditProfileScreen.showsInsurerIK(appLanguage: nil))
        }

        // MARK: - Catalog: one word per thing

        @Test("German saves with one word, and the card and the sheet both postpone")
        func oneWordPerAction() throws {
            let catalog = try ParityCatalog.load()
            func german(_ key: String) -> String? {
                catalog.strings[key].flatMap { ParityCatalog.value($0, language: "de") }
            }
            #expect(german(HLControlWord.save.catalogKey) == german("Save"))
            #expect(german("vorsorge.card.action.snooze") == german("vorsorge.action.snooze"))
        }

        @Test("English and Dutch name a page like its tab")
        func pagesNamedLikeTabs() throws {
            let catalog = try ParityCatalog.load()
            func value(_ key: String, _ language: String) -> String? {
                catalog.strings[key].flatMap { ParityCatalog.value($0, language: language) }
            }
            #expect(value("capture.picker.title", "en") == value("Log", "en"))
            #expect(value("Medications", "nl") == value("Meds", "nl"))
            #expect(value("reminders.manage.title", "en") == value("Preventive care", "en"))
        }

        @Test("workout counts keep each number with its word")
        func countsDoNotBreakBetweenNumberAndWord() throws {
            let catalog = try ParityCatalog.load()
            let entry = try #require(catalog.strings["settings.hkdiag.workout_counts %lld %lld %lld %lld"])
            for language in ["de", "en", "nl"] {
                let text = try #require(ParityCatalog.value(entry, language: language))
                #expect(!text.contains("lld "), "\(language): a plain space after a number lets the line break there")
            }
        }
    }

#endif
