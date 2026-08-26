import Foundation
@testable import HealthLog
import Testing

/// **v0.9.0 W2** — pins the pure AlarmKit routing + schedule-mapping
/// (`CriticalMedAlarmRouting`): the alarm-vs-UNNotification routing
/// predicate (coexistence = REPLACE), the weekly slot mapping, and the
/// deterministic alarm-id derivation. AlarmKit-free so it runs on the host
/// without iOS 26.
@Suite("CriticalMedAlarmRouting — alarm-vs-UN routing + schedule mapping")
struct CriticalMedAlarmRoutingTests {
    private func med(
        id: String = "m1",
        active: Bool = true,
        notificationsEnabled: Bool = true,
        times: [TimeOfDay] = [TimeOfDay(hour: 9, minute: 0)],
        weekdays: Set<Weekday>? = nil,
        intervalWeeks: Int = 1
    ) -> Medication {
        Medication(
            id: id,
            name: "Med \(id)",
            dose: "5 mg",
            schedule: MedicationSchedule(times: times, weekdays: weekdays, intervalWeeks: intervalWeeks),
            notificationsEnabled: notificationsEnabled,
            active: active
        )
    }

    // MARK: - Eligibility

    @Test("Eligible when iOS 26 + authorized + opted-in + active + weekly")
    func eligibleHappyPath() {
        let m = med()
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: m,
            alarmEnabled: { _ in true },
            authorized: true,
            osAvailable: true
        ) == true)
    }

    @Test("Ineligible on iOS < 26 (osAvailable == false)")
    func ineligibleOldOS() {
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: med(),
            alarmEnabled: { _ in true },
            authorized: true,
            osAvailable: false
        ) == false)
    }

    @Test("Ineligible when AlarmKit unauthorized")
    func ineligibleUnauthorized() {
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: med(),
            alarmEnabled: { _ in true },
            authorized: false,
            osAvailable: true
        ) == false)
    }

    @Test("Ineligible when the per-med opt-in is OFF")
    func ineligibleOptedOut() {
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: med(),
            alarmEnabled: { _ in false },
            authorized: true,
            osAvailable: true
        ) == false)
    }

    @Test("Ineligible when archived or notifications off")
    func ineligibleInactive() {
        let archived = med(active: false)
        let noNotif = med(notificationsEnabled: false)
        let predicate: (String) -> Bool = { _ in true }
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: archived, alarmEnabled: predicate, authorized: true, osAvailable: true
        ) == false)
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: noNotif, alarmEnabled: predicate, authorized: true, osAvailable: true
        ) == false)
    }

    @Test("Biweekly GLP-1 (intervalWeeks > 1) is now alarm-eligible (v0.10 R1 §3.5)")
    func eligibleBiweekly() {
        // Generalised routing: biweekly schedules a single-shot .fixed alarm
        // at the engine's next occurrence rather than dropping to the UN path.
        let biweekly = med(weekdays: [.mon], intervalWeeks: 2)
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: biweekly,
            alarmEnabled: { _ in true },
            authorized: true,
            osAvailable: true
        ) == true)
    }

    @Test("Ineligible when the schedule has no times")
    func ineligibleNoTimes() {
        #expect(CriticalMedAlarmRouting.isAlarmEligible(
            medication: med(times: []),
            alarmEnabled: { _ in true },
            authorized: true,
            osAvailable: true
        ) == false)
    }

    // MARK: - Routing (REPLACE)

    @Test("route partitions alarm-owned meds out of the UN set")
    func routePartitions() {
        let critical = med(id: "critical")
        let normal = med(id: "normal")
        let biweekly = med(id: "biweekly", weekdays: [.mon], intervalWeeks: 2)
        let alarmOn: Set = ["critical", "biweekly"] // user opted both in
        let (alarmMeds, unMeds) = CriticalMedAlarmRouting.route(
            medications: [critical, normal, biweekly],
            alarmEnabled: { alarmOn.contains($0) },
            authorized: true,
            osAvailable: true
        )
        // v0.10 R1 §3.5 — critical AND biweekly are both opted-in + eligible
        // (biweekly schedules a fixed next-occurrence alarm); normal is not
        // opted in so it stays on the UN path.
        #expect(Set(alarmMeds.map(\.id)) == ["critical", "biweekly"])
        #expect(unMeds.map(\.id) == ["normal"])
    }

    @Test("route returns all meds on UN when unauthorized")
    func routeUnauthorizedAllUN() {
        let meds = [med(id: "a"), med(id: "b")]
        let (alarmMeds, unMeds) = CriticalMedAlarmRouting.route(
            medications: meds,
            alarmEnabled: { _ in true },
            authorized: false,
            osAvailable: true
        )
        #expect(alarmMeds.isEmpty)
        #expect(unMeds.count == 2)
    }

    // MARK: - Schedule mapping

    @Test("alarmSlots produces one slot per time, carrying the weekday set")
    func alarmSlotsMapping() {
        let m = med(
            times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 30)],
            weekdays: [.mon, .wed, .fri]
        )
        let slots = CriticalMedAlarmRouting.alarmSlots(for: m)
        #expect(slots.count == 2)
        #expect(slots[0] == CriticalMedAlarmRouting.AlarmSlot(
            hour: 8, minute: 0, weekdays: [.mon, .wed, .fri]
        ))
        #expect(slots[1].hour == 20)
        #expect(slots[1].minute == 30)
        // Weekdays are sorted ascending (Sun=0…Sat=6).
        #expect(slots[0].weekdays == [.mon, .wed, .fri])
    }

    @Test("alarmSlots with no weekday constraint yields empty weekdays (= every day)")
    func alarmSlotsDaily() {
        let slots = CriticalMedAlarmRouting.alarmSlots(for: med(weekdays: nil))
        #expect(slots.count == 1)
        #expect(slots[0].weekdays.isEmpty)
    }

    // MARK: - Deterministic alarm ids

    @Test("alarmID is stable for the same (med, slot) and distinct otherwise")
    func alarmIDDeterminism() {
        let a1 = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let a1Repeat = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let a1Slot1 = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 1)
        let a2 = CriticalMedAlarmRouting.alarmID(medicationID: "m2", slotIndex: 0)
        #expect(a1 == a1Repeat) // stable → idempotent reconcile
        #expect(a1 != a1Slot1) // different slot → different id
        #expect(a1 != a2) // different med → different id
    }

    @Test("alarmID is a valid v5 UUID (version + variant bits set)")
    func alarmIDVersionBits() {
        let id = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect((bytes[6] & 0xF0) == 0x50) // version 5
        #expect((bytes[8] & 0xC0) == 0x80) // RFC-4122 variant
    }

    // MARK: - Orphan purge: snooze survival + removal (HIGH-1 / HIGH-2)

    @Test("snooze slot index is outside the scheduled-slot ceiling")
    func snoozeSlotOutsideScheduledRange() {
        #expect(CriticalMedAlarmRouting.snoozeSlotIndex >= CriticalMedAlarmRouting.maxScheduledSlots)
    }

    @Test("C-H1: routine reconcile does NOT purge a pending snooze of an active med")
    func orphanPurgeKeepsPendingSnooze() {
        // m1 is alarm-owned with one scheduled slot AND a pending snooze.
        let scheduled = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let snooze = CriticalMedAlarmRouting.snoozeAlarmID(medicationID: "m1")
        // A routine reconcile only ever puts scheduled slots in the desired set.
        let desired: Set<UUID> = [scheduled]
        let orphans = CriticalMedAlarmRouting.orphanIDs(
            existing: [scheduled, snooze],
            desiredScheduledIDs: desired,
            activeMedIDs: ["m1"]
        )
        // The snooze must be protected (med still active) → not cancelled.
        #expect(orphans.isEmpty)
        #expect(!orphans.contains(snooze))
    }

    @Test("C-H2: snooze of a removed med IS purged on reconcile")
    func orphanPurgeCancelsRemovedMedSnooze() {
        // m1 stays active; m2 was toggled off / archived (no longer in
        // activeMedIDs, no desired slots) but still has a pending snooze.
        let m1Scheduled = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let m1Snooze = CriticalMedAlarmRouting.snoozeAlarmID(medicationID: "m1")
        let m2Snooze = CriticalMedAlarmRouting.snoozeAlarmID(medicationID: "m2")
        let orphans = CriticalMedAlarmRouting.orphanIDs(
            existing: [m1Scheduled, m1Snooze, m2Snooze],
            desiredScheduledIDs: [m1Scheduled],
            activeMedIDs: ["m1"]
        )
        // Only the gone med's snooze is purged; the active med's pair survives.
        #expect(orphans == [m2Snooze])
    }

    @Test("orphan purge cancels a stale scheduled slot of a shrunk schedule")
    func orphanPurgeCancelsStaleSlot() {
        // m1 dropped from 2 slots to 1; the stale slot-1 must be purged.
        let slot0 = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 0)
        let slot1 = CriticalMedAlarmRouting.alarmID(medicationID: "m1", slotIndex: 1)
        let orphans = CriticalMedAlarmRouting.orphanIDs(
            existing: [slot0, slot1],
            desiredScheduledIDs: [slot0],
            activeMedIDs: ["m1"]
        )
        #expect(orphans == [slot1])
    }

    // MARK: - v0.10 R1 §3.5 — generalised planner

    private func entryMed(
        id: String = "m1",
        cadence: Cadence,
        time: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
        lastTakenAt: Date? = nil,
        startsOn: Date? = nil,
        oneShot: Bool = false
    ) -> Medication {
        let entry = ScheduleEntry(cadence: cadence, timesOfDay: [time], windowStart: time)
        return Medication(
            id: id,
            name: "Med \(id)",
            dose: "5 mg",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTakenAt,
            notificationsEnabled: true,
            active: true,
            startsOn: startsOn,
            oneShot: oneShot
        )
    }

    @Test("daily cadence plans recurring weekly slots (no weekday constraint)")
    func plannedDaily() {
        let planned = CriticalMedAlarmRouting.plannedAlarms(for: entryMed(cadence: .daily))
        #expect(planned.count == 1)
        if case let .weekly(slot) = planned[0] {
            #expect(slot.weekdays.isEmpty)
        } else {
            Issue.record("expected .weekly plan")
        }
    }

    @Test("weekday cadence plans a recurring weekly slot carrying the weekday set")
    func plannedWeekdays() {
        let planned = CriticalMedAlarmRouting.plannedAlarms(for: entryMed(cadence: .weekdays([.mon, .thu])))
        #expect(planned.count == 1)
        if case let .weekly(slot) = planned[0] {
            #expect(slot.weekdays == [.mon, .thu])
        } else {
            Issue.record("expected .weekly plan")
        }
    }

    @Test("rolling cadence plans a single fixed alarm at the next occurrence")
    func plannedRolling() {
        let lastTaken = Date().addingTimeInterval(-2 * 86400)
        let planned = CriticalMedAlarmRouting.plannedAlarms(
            for: entryMed(cadence: .rolling(intervalDays: 30), lastTakenAt: lastTaken)
        )
        #expect(planned.count == 1)
        if case .fixed = planned[0] {} else { Issue.record("expected .fixed plan") }
    }

    @Test("biweekly cadence plans a single fixed alarm (no clean AlarmKit recurrence)")
    func plannedBiweekly() {
        let planned = CriticalMedAlarmRouting.plannedAlarms(
            for: entryMed(cadence: .everyNWeeks(interval: 2, days: [.mon]))
        )
        #expect(planned.count == 1)
        if case .fixed = planned[0] {} else { Issue.record("expected .fixed plan") }
    }

    @Test("monthly cadence plans a single fixed alarm")
    func plannedMonthly() {
        let planned = CriticalMedAlarmRouting.plannedAlarms(for: entryMed(cadence: .monthly(day: 1)))
        #expect(planned.count == 1)
        if case .fixed = planned[0] {} else { Issue.record("expected .fixed plan") }
    }
}
