import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// A dose recorded anywhere silences exactly its own local reminder, and a
/// reminder acted on abroad books the account-zone slot it stands for.
@Suite("Medication reminder completion and slot mapping")
struct MedicationReminderCompletionTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func date(_ zone: TimeZone, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func intake(_ id: String, med: String, at: Date, status: IntakeStatus) -> MedicationIntake {
        MedicationIntake(id: id, medicationId: med, scheduledAt: at, takenAt: status == .taken ? at : nil, status: status)
    }

    // MARK: - Which slots

    @Test("only taken and skipped slots of the server list count")
    func resolvedSlotsFilter() {
        let at = date(berlin, 11, 8)
        let slots = MedicationReminderCompletion.resolvedSlots(in: [
            intake("a", med: "m", at: at, status: .taken),
            intake("b", med: "m", at: at.addingTimeInterval(3600), status: .skipped),
            intake("c", med: "m", at: at.addingTimeInterval(7200), status: .pending)
        ])
        #expect(slots.map(\.scheduledAt) == [at, at.addingTimeInterval(3600)])
    }

    // MARK: - Which events

    @Test("at home: the 08:00 dose silences the 08:00 reminder and not the 08:30 one")
    func ownSlotOnly() {
        let events = [
            MedicationReminderCompletion.ReminderEvent(index: 0, medicationId: "m", start: date(berlin, 11, 8)),
            MedicationReminderCompletion.ReminderEvent(index: 1, medicationId: "m", start: date(berlin, 11, 8, 30))
        ]
        let picks = MedicationReminderCompletion.eventsToComplete(
            events: events,
            slots: [.init(medicationId: "m", scheduledAt: date(berlin, 11, 8))],
            deviceTimeZone: berlin,
            accountTimeZone: berlin
        )
        #expect(picks == [0])
    }

    @Test("another medication's reminder at the same time stays")
    func otherMedicationStays() {
        let events = [
            MedicationReminderCompletion.ReminderEvent(index: 0, medicationId: "other", start: date(berlin, 11, 8))
        ]
        let picks = MedicationReminderCompletion.eventsToComplete(
            events: events,
            slots: [.init(medicationId: "m", scheduledAt: date(berlin, 11, 8))],
            deviceTimeZone: berlin,
            accountTimeZone: berlin
        )
        #expect(picks.isEmpty)
    }

    @Test("a minute of server drift still matches")
    func driftMatches() {
        let events = [MedicationReminderCompletion.ReminderEvent(index: 3, medicationId: "m", start: date(berlin, 11, 8))]
        let picks = MedicationReminderCompletion.eventsToComplete(
            events: events,
            slots: [.init(medicationId: "m", scheduledAt: date(berlin, 11, 8, 1))],
            deviceTimeZone: berlin,
            accountTimeZone: berlin
        )
        #expect(picks == [3])
    }

    @Test("in New York with a Berlin account: the Berlin 08:00 slot silences the local 08:00 reminder")
    func travelWallClock() {
        let events = [
            MedicationReminderCompletion.ReminderEvent(index: 0, medicationId: "m", start: date(newYork, 11, 8)),
            MedicationReminderCompletion.ReminderEvent(index: 1, medicationId: "m", start: date(newYork, 12, 8))
        ]
        let picks = MedicationReminderCompletion.eventsToComplete(
            events: events,
            slots: [.init(medicationId: "m", scheduledAt: date(berlin, 11, 8))],
            deviceTimeZone: newYork,
            accountTimeZone: berlin
        )
        #expect(picks == [0])
    }

    // MARK: - Slot of a fired reminder

    @Test("same zone: the delivery instant is the slot")
    func sameZoneKeepsDelivery() {
        let delivered = date(berlin, 11, 8).addingTimeInterval(20)
        #expect(MedicationReminderSlot.accountSlot(deliveredAt: delivered, deviceTimeZone: berlin, accountTimeZone: berlin) == delivered)
    }

    @Test("west of the account zone: the earlier account slot of the same clock time")
    func westMapsBack() {
        let delivered = date(newYork, 11, 8)
        let slot = MedicationReminderSlot.accountSlot(deliveredAt: delivered, deviceTimeZone: newYork, accountTimeZone: berlin)
        #expect(slot == date(berlin, 11, 8))
    }

    @Test("east of the account zone: no future slot, the delivery instant stays")
    func eastKeepsDelivery() {
        let delivered = date(tokyo, 11, 8)
        let slot = MedicationReminderSlot.accountSlot(deliveredAt: delivered, deviceTimeZone: tokyo, accountTimeZone: berlin)
        #expect(slot == delivered)
    }

    @MainActor
    @Test("a Spezi banner resolves to the account slot when an account zone is given")
    func resolvedPayloadMapsSlot() throws {
        var info = NotificationService.medicationUserInfo(medicationId: "med_1", scheduleId: nil, scheduledFor: date(berlin, 10, 20))
        info["speziScheduled"] = true
        let delivered = MedicationReminderSlot.accountSlot(
            deliveredAt: date(newYork, 11, 8),
            deviceTimeZone: newYork,
            accountTimeZone: berlin
        )
        let payload = try #require(NotificationService.resolvedPayload(userInfo: info, deliveredAt: delivered))
        #expect(payload.scheduledFor == date(berlin, 11, 8))
    }
}
