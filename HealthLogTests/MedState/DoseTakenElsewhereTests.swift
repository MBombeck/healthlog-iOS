import Foundation
@testable import HealthLog
import Testing

// #189 — a dose taken elsewhere (pill box, Telegram) must withdraw the
// phone's reminders and must not be taken twice.

@Suite("#189 (1) — the MEDICATION_INTAKE_RECORDED confirmation push")
struct IntakeRecordedPushTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the final flat fields parse; the 1.7 draft's nested slot and source do not")
    func parsesFinalNames() throws {
        let flat: [AnyHashable: Any] = [
            "eventType": "MEDICATION_INTAKE_RECORDED",
            "medicationId": "med-1",
            "intakeId": "row-1",
            "slotInstant": "2027-01-15T08:00:00.000Z",
            "outcome": "taken",
            "takenAt": "2027-01-15T07:12:00Z",
            "takenVia": "INTEGRATION"
        ]
        let dose = try #require(MedicationIntakeRecordedPush.parse(userInfo: flat))
        #expect(dose.medicationId == "med-1")
        #expect(dose.source == "INTEGRATION")
        #expect(dose.takenAt != nil)
        let draft: [AnyHashable: Any] = [
            "eventType": "MEDICATION_INTAKE_RECORDED",
            "medicationId": "med-1",
            "slot": ["id": "slot-9", "instant": "2027-01-15T08:00:00.000Z"],
            "takenAt": "2027-01-15T07:12:00Z",
            "source": "API"
        ]
        #expect(MedicationIntakeRecordedPush.parse(userInfo: draft) == nil)
    }

    @Test("another event, no medication or no slot: no confirmation")
    func rejectsIncomplete() {
        #expect(MedicationIntakeRecordedPush.parse(userInfo: [
            "eventType": "MEDICATION_INTAKE_SYNC",
            "medicationId": "m",
            "slotInstant": "2027-01-15T08:00:00Z",
            "outcome": "taken"
        ]) == nil)
        #expect(MedicationIntakeRecordedPush.parse(userInfo: [
            "eventType": "MEDICATION_INTAKE_RECORDED",
            "slotInstant": "2027-01-15T08:00:00Z",
            "outcome": "taken"
        ]) == nil)
        #expect(MedicationIntakeRecordedPush.parse(userInfo: ["eventType": "MEDICATION_INTAKE_RECORDED", "medicationId": "m"]) == nil)
    }

    @Test("the gate is shut until /api/auth/me reports the capability")
    func gateShutByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-189-\(UUID().uuidString)"))
        #expect(!MedicationIntakeRecordedGate.isOpen(defaults: defaults))
        MedicationCapabilities.record([.intakeRecordedPush], defaults: defaults)
        #expect(MedicationIntakeRecordedGate.isOpen(defaults: defaults))
        MedicationCapabilities.record([], defaults: defaults)
        #expect(!MedicationIntakeRecordedGate.isOpen(defaults: defaults))
    }

    @Test("the ledger keeps one entry per slot and answers contains within the drift")
    func ledger() {
        let ledger = ResolvedDoseLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json"))
        ledger.record(ResolvedDose(medicationId: "m", slotAt: slot, recordedAt: slot), now: slot)
        ledger.record(ResolvedDose(medicationId: "m", slotAt: slot, source: "WEB", recordedAt: slot), now: slot)
        #expect(ledger.read().count == 1)
        #expect(ledger.contains(medicationId: "m", slotAt: slot.addingTimeInterval(120)))
        #expect(!ledger.contains(medicationId: "m", slotAt: slot.addingTimeInterval(3600)))
        // Old entries fall off with the next write.
        ledger.record(ResolvedDose(medicationId: "n", slotAt: slot, recordedAt: slot), now: slot.addingTimeInterval(3 * 86400))
        #expect(ledger.read().map(\.medicationId) == ["n"])
    }
}

@MainActor
@Suite("#189 (1-3) — which reminders a resolved dose withdraws")
struct ResolvedReminderPlanTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)
    private var dose: ResolvedDose {
        ResolvedDose(medicationId: "med-1", slotAt: slot)
    }

    @Test("the Spezi banner, the snooze and the reopen of that slot go; other slots and medications stay")
    func matchesThisDoseOnly() {
        let iso = ISO8601DateFormatter().string(from: slot)
        let reminders = [
            ResolvedReminderPlan.reminder(identifier: "spezi", userInfo: ["medicationId": "med-1", "speziScheduled": true], firesAt: slot),
            ResolvedReminderPlan.reminder(
                identifier: "snooze",
                userInfo: ["medicationId": "med-1", "scheduledFor": iso],
                firesAt: slot.addingTimeInterval(900)
            ),
            ResolvedReminderPlan.reminder(
                identifier: "evening",
                userInfo: ["medicationId": "med-1", "speziScheduled": true],
                firesAt: slot.addingTimeInterval(12 * 3600)
            ),
            ResolvedReminderPlan.reminder(identifier: "other", userInfo: ["medicationId": "med-2", "scheduledFor": iso], firesAt: slot),
            ResolvedReminderPlan.reminder(identifier: "mood", userInfo: [:], firesAt: slot)
        ]
        #expect(ResolvedReminderPlan.identifiersToRemove(reminders, doses: [dose]) == ["spezi", "snooze"])
    }

    @Test("a repeating trigger is carried on as single requests for the following days")
    func carryDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let dates = ResolvedReminderPlan.carryDates(
            matching: DateComponents(hour: 8, minute: 0),
            after: slot,
            calendar: calendar,
            limit: ResolvedReminderPlan.carryHorizonDays
        )
        #expect(dates.count == ResolvedReminderPlan.carryHorizonDays)
        #expect(dates.allSatisfy { $0 > slot })
        #expect(dates.allSatisfy { calendar.component(.hour, from: $0) == 8 })
    }

    @Test("the snooze id follows from medication and slot")
    func snoozeIdentifier() {
        let first = NotificationService.snoozeIdentifier(medicationId: "med-1", scheduledFor: slot)
        #expect(first == NotificationService.snoozeIdentifier(medicationId: "med-1", scheduledFor: slot))
        #expect(first == "snooze-med-1-1800000000")
        #expect(NotificationService.snoozeIdentifier(medicationId: "med-1", scheduledFor: nil).hasPrefix("snooze-med-1-"))
    }

    @Test("today's resolved slots feed the withdrawal")
    func resolvedDoses() {
        let intakes = [
            MedicationIntake(id: "a", medicationId: "med-1", scheduledAt: slot, takenAt: slot, status: .taken),
            MedicationIntake(id: "b", medicationId: "med-1", scheduledAt: slot.addingTimeInterval(3600), takenAt: nil, status: .pending)
        ]
        let doses = AppContainer.resolvedDoses(in: intakes)
        #expect(doses.map(\.medicationId) == ["med-1"])
        #expect(doses.map(\.slotAt) == [slot])
    }
}

@Suite("#189 (6, 7) — no second dose")
struct AlreadyTakenTests {
    private let slot = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("an already-taken answer settles the dose on the widget and the Live Activity")
    func settles() {
        let already = MedicationAlreadyTaken(takenAt: slot, source: "API")
        #expect(WidgetDoseOutcomeStore.kind(signedIn: true, error: already) == .recorded)
        #if canImport(ActivityKit)
            #expect(MarkDoseFromLiveActivityIntent.commitOutcome(signedIn: true, error: already) == .recorded)
        #endif
        #expect(already.message.contains(slot.formatted(date: .omitted, time: .shortened)))
        #expect(MedicationAlreadyTaken(takenAt: nil, source: nil).message.isEmpty == false)
    }

    @Test("the taken row of the same slot is found after a re-read")
    func takenSibling() {
        let open = MedicationIntake(id: "synth:med-1|x", medicationId: "med-1", scheduledAt: slot, takenAt: nil, status: .pending)
        let taken = MedicationIntake(
            id: "srv",
            medicationId: "med-1",
            scheduledAt: slot.addingTimeInterval(20),
            takenAt: slot,
            status: .taken
        )
        let other = MedicationIntake(
            id: "o",
            medicationId: "med-1",
            scheduledAt: slot.addingTimeInterval(3600),
            takenAt: slot,
            status: .taken
        )
        #expect(MedicationsStore.takenSibling(of: open, in: [open, other, taken])?.id == "srv")
        #expect(MedicationsStore.takenSibling(of: open, in: [open, other]) == nil)
    }

    @Test("a due dose from a snapshot written long before it shows no button")
    func widgetTrust() {
        let evening = slot.addingTimeInterval(-10 * 3600)
        #expect(!WidgetTimelinePolicy.isNextDoseUntrusted(generatedAt: evening, scheduledAt: slot, now: slot.addingTimeInterval(-60)))
        #expect(WidgetTimelinePolicy.isNextDoseUntrusted(generatedAt: evening, scheduledAt: slot, now: slot))
        let recent = slot.addingTimeInterval(-30 * 60)
        #expect(!WidgetTimelinePolicy.isNextDoseUntrusted(generatedAt: recent, scheduledAt: slot, now: slot.addingTimeInterval(600)))
        #expect(WidgetTimelinePolicy.isNextDoseUntrusted(generatedAt: recent, scheduledAt: nil, now: recent.addingTimeInterval(17 * 3600)))
    }
}
