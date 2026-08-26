import Foundation
@testable import HealthLog
import Testing

/// AUDIT-v0162 H2 — pins the pure redaction decision shared by the
/// Notification Service Extension. Given the visible title/body + the
/// hide-on/off opt-out + the push category/eventType, the redactor either
/// passes the text through unchanged or swaps in the neutral placeholder. No
/// `UNNotification*` / bundle dependency, so the decision is exercised in
/// isolation here (the NSE only resolves the localized placeholders + applies
/// the result).
@Suite("MedicationReminderRedactor — lock-screen med-name redaction")
struct MedicationReminderRedactorTests {
    private let realTitle = "Sertralin"
    private let realBody = "50 mg um 08:00"
    private let phTitle = "Medication reminder"
    private let phBody = "It's time for your medication."

    private func redact(
        category: String?,
        eventType: String?,
        hide: Bool
    ) -> MedicationReminderRedactor.Content {
        MedicationReminderRedactor.redactedContent(
            title: realTitle,
            body: realBody,
            category: category,
            eventType: eventType,
            hideMedicationName: hide,
            placeholderTitle: phTitle,
            placeholderBody: phBody
        )
    }

    @Test("Med reminder + hide ON → title/body redacted to placeholder")
    func medReminderHideOnRedacts() {
        let out = redact(category: "MEDICATION_REMINDER", eventType: nil, hide: true)
        #expect(out.title == phTitle)
        #expect(out.body == phBody)
    }

    @Test("Med reminder + hide OFF → passthrough (real name shown)")
    func medReminderHideOffPassesThrough() {
        let out = redact(category: "MEDICATION_REMINDER", eventType: nil, hide: false)
        #expect(out.title == realTitle)
        #expect(out.body == realBody)
    }

    @Test("Marker via eventType (no aps.category) + hide ON → redacted")
    func eventTypeMarkerHideOnRedacts() {
        let out = redact(category: nil, eventType: "MEDICATION_REMINDER", hide: true)
        #expect(out.title == phTitle)
        #expect(out.body == phBody)
    }

    @Test("Non-medication category + hide ON → passthrough (untouched)")
    func nonMedicationHideOnPassesThrough() {
        let out = redact(category: "MOOD_REMINDER", eventType: "MOOD_REMINDER", hide: true)
        #expect(out.title == realTitle)
        #expect(out.body == realBody)
    }

    @Test("No category + no eventType + hide ON → passthrough (not a reminder)")
    func noMarkerHideOnPassesThrough() {
        let out = redact(category: nil, eventType: nil, hide: true)
        #expect(out.title == realTitle)
        #expect(out.body == realBody)
    }

    @Test("isMedicationReminder matches on either category or eventType")
    func isMedicationReminderMatch() {
        #expect(MedicationReminderRedactor.isMedicationReminder(category: "MEDICATION_REMINDER", eventType: nil))
        #expect(MedicationReminderRedactor.isMedicationReminder(category: nil, eventType: "MEDICATION_REMINDER"))
        #expect(!MedicationReminderRedactor.isMedicationReminder(category: "SYSTEM_ALERT", eventType: nil))
        #expect(!MedicationReminderRedactor.isMedicationReminder(category: nil, eventType: nil))
    }
}
