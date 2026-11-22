import Foundation
@testable import HealthLog
import Testing

/// W-B188 (AUDIT-SEC-b187 High) — the device-local "hide medication name on
/// lock screen" opt-out. Pins the default-OFF contract + round-trip
/// persistence on an isolated `UserDefaults` suite (no shared-state leak into
/// the standard domain).
@Suite("LockScreenPrivacy — hide-medication-name opt-out")
struct LockScreenPrivacyTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "test.lockScreenPrivacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Defaults to OFF (current behaviour — real name shown)")
    func defaultsOff() throws {
        let defaults = try makeDefaults()
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == false)
    }

    @Test("Persists the opt-in choice")
    func persistsOn() throws {
        let defaults = try makeDefaults()
        LockScreenPrivacy.setHideMedicationName(true, defaults: defaults)
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == true)
    }

    @Test("Can be turned back off")
    func togglesBackOff() throws {
        let defaults = try makeDefaults()
        LockScreenPrivacy.setHideMedicationName(true, defaults: defaults)
        LockScreenPrivacy.setHideMedicationName(false, defaults: defaults)
        #expect(LockScreenPrivacy.hideMedicationName(defaults: defaults) == false)
    }
}

#if !SWIFT_PACKAGE
    /// D4 (1.7) — "hide medication names" holds on every surface that names a
    /// medication: the AlarmKit alarm, the low-supply heads-up (local and pushed),
    /// Siri's confirmation, and it holds from the tap on.
    @Suite("Hide medication names — every surface, at once")
    struct HideMedicationNamesSurfacesTests {
        #if canImport(AlarmKit)
            @Test("the critical alarm names no medication and no dose with the switch on")
            func alarmTitleHidesName() {
                let hidden = CriticalMedAlarmService.alertTitle(name: "Sertralin", dose: "50 mg", hidesName: true)
                #expect(hidden.key == "alarm.med.title")
                let shown = CriticalMedAlarmService.alertTitle(name: "Sertralin", dose: "50 mg", hidesName: false)
                #expect(shown.key != "alarm.med.title")
                #expect(String(localized: shown).contains("Sertralin"))
            }
        #endif

        #if canImport(UserNotifications)
            @Test("the local low-supply heads-up names no medication with the switch on")
            func localLowSupplyHidesName() {
                let hidden = NotificationService.buildLowSupplyRequest(
                    medicationID: "med-42", medicationName: "Lisinopril", runwayDays: 3, hidesName: true
                )
                #expect(!hidden.content.body.contains("Lisinopril"))
                #expect(!hidden.content.title.contains("Lisinopril"))
                #expect(hidden.content.body == String(localized: "med.lowstock.push.body.hidden"))
                // The tap still opens the medication.
                #expect(hidden.content.userInfo["medicationId"] as? String == "med-42")
                let shown = NotificationService.buildLowSupplyRequest(
                    medicationID: "med-42", medicationName: "Lisinopril", runwayDays: 3, hidesName: false
                )
                #expect(shown.content.body.contains("Lisinopril"))
            }

            @Test("the extension's marker is the app's low-supply category")
            func lowStockMarkerMatchesCategory() {
                #expect(MedicationReminderRedactor.lowStockCategory == NotificationService.categoryMedicationLowStock)
                #expect(MedicationReminderRedactor.lowStockCategory == NotificationService.eventTypeLowSupply)
            }
        #endif

        @Test("a pushed low-supply alert is redacted with its own placeholders, else the reminder ones")
        func pushedLowStockIsRedacted() {
            func redact(hide: Bool, lowStock: (String, String)?) -> MedicationReminderRedactor.Content {
                MedicationReminderRedactor.redactedContent(
                    title: "Supply running low",
                    body: "Lisinopril lasts 3 more days.",
                    category: "MEDICATION_LOW_STOCK",
                    eventType: nil,
                    hideMedicationName: hide,
                    placeholderTitle: "Medication reminder",
                    placeholderBody: "It's time for your medication.",
                    lowStockPlaceholderTitle: lowStock?.0,
                    lowStockPlaceholderBody: lowStock?.1
                )
            }
            let own = redact(hide: true, lowStock: ("Supply running low", "A medication is running low."))
            #expect(own == .init(title: "Supply running low", body: "A medication is running low."))
            // The relay path passes no low-supply text; the name goes all the same.
            let fallback = redact(hide: true, lowStock: nil)
            #expect(fallback == .init(title: "Medication reminder", body: "It's time for your medication."))
            let off = redact(hide: false, lowStock: ("x", "y"))
            #expect(off.body == "Lisinopril lasts 3 more days.")
            #expect(MedicationReminderRedactor.isLowStock(category: nil, eventType: "MEDICATION_LOW_STOCK"))
        }

        @MainActor
        @Test("Siri names no medication with the switch on or the iPhone locked")
        func siriConfirmationHidesName() {
            #expect(IntentMedicationNamePrivacy.hidesNames(switchOn: true, locked: false))
            #expect(IntentMedicationNamePrivacy.hidesNames(switchOn: false, locked: true))
            #expect(!IntentMedicationNamePrivacy.hidesNames(switchOn: false, locked: false))
            let hidden = MarkMedicationTakenIntent.confirmation(medicationName: "Sertralin", hidesName: true)
            #expect(!String(localized: hidden).contains("Sertralin"))
            let shown = MarkMedicationTakenIntent.confirmation(medicationName: "Sertralin", hidesName: false)
            #expect(String(localized: shown).contains("Sertralin"))
        }

        @MainActor
        @Test("flipping the switch ends the running Live Activity before everything is planned again")
        func switchFlipReplansInOrder() async {
            var steps: [String] = []
            await AppContainer.applyLockScreenPrivacyChange(
                endMedicationLiveActivities: { steps.append("end") },
                replan: { steps.append("replan") }
            )
            #expect(steps == ["end", "replan"])
        }
    }
#endif
