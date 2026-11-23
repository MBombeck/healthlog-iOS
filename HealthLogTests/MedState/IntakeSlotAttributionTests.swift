import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

// #191 — the one intake form says where a logged dose counts before it is
// saved, by the web's `slot-attribution.ts` rule: within ±60 min of the
// nearest dose time that day it counts for that slot (`scheduledFor`), 1 to 4 h
// off it counts as late unless switched off (`forceSlotInstant`), else it is
// an extra dose; a skip names the nearest slot; no dose times, no skip.

@Suite("Intake slot attribution (#191 one intake form)")
struct IntakeSlotAttributionTests {
    static let zone = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        MedicationDueRule.calendar(timeZone: zone)
    }

    /// 2026-11-20 at `hour:minute` in Berlin.
    static func at(_ hour: Int, _ minute: Int, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    static func tod(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
        TimeOfDay(hour: hour, minute: minute)
    }

    static func medication(
        dose: String = "5 mg",
        entries: [ScheduleEntry],
        asNeeded: Bool = false
    ) -> Medication {
        Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: dose,
            schedule: MedicationSchedule(entries: entries),
            asNeeded: asNeeded
        )
    }

    static func daily(_ times: [TimeOfDay], dose: String? = nil) -> ScheduleEntry {
        ScheduleEntry(cadence: .daily, timesOfDay: times, dose: dose, windowStart: times.first ?? tod(8))
    }

    static func resolve(
        _ takenAt: Date,
        _ times: [TimeOfDay] = [tod(8)],
        skipped: Bool = false,
        countNear: Bool = true
    ) -> IntakeSlotAttribution {
        IntakeSlotAttribution.resolve(
            takenAt: takenAt,
            times: times,
            skipped: skipped,
            countNear: countNear,
            calendar: calendar
        )
    }

    // MARK: - Exact

    @Test("a take within 60 min counts for the slot and writes scheduledFor")
    func exactTake() {
        let attribution = Self.resolve(Self.at(8, 30))
        guard case let .slot(slot) = attribution else {
            Issue.record("expected .slot, got \(attribution)")
            return
        }
        #expect(slot.time == Self.tod(8))
        #expect(slot.instant == Self.at(8, 0))
        #expect(slot.gapMinutes == 30)
        #expect(attribution.scheduledFor == Self.at(8, 0))
        #expect(attribution.forceSlotInstant == nil)
        #expect(attribution.nearSlot == nil, "no switch for an on-time take")
    }

    @Test("a take before the slot counts too (the gap is unsigned)")
    func earlyTake() {
        #expect(Self.resolve(Self.at(7, 15)).scheduledFor == Self.at(8, 0))
    }

    @Test("60 minutes off is still on time, 61 is late")
    func sixtyMinuteEdge() {
        #expect(IntakeSlotAttribution.classify(IntakeSlotAttribution.nearestSlot(
            takenAt: Self.at(9, 0), times: [Self.tod(8)], calendar: Self.calendar
        )) == .exact)
        if case .slot = Self.resolve(Self.at(9, 0)) {} else { Issue.record("09:00 must count on time") }
        if case .late = Self.resolve(Self.at(9, 1)) {} else { Issue.record("09:01 must count as late") }
        if case .slot = Self.resolve(Self.at(7, 0)) {} else { Issue.record("07:00 must count on time") }
    }

    // MARK: - Near

    @Test("a take 1 to 4 h off counts as late with the switch on (forceSlotInstant)")
    func nearSwitchOn() {
        let attribution = Self.resolve(Self.at(10, 30))
        guard case let .late(slot) = attribution else {
            Issue.record("expected .late, got \(attribution)")
            return
        }
        #expect(slot.instant == Self.at(8, 0))
        #expect(attribution.forceSlotInstant == Self.at(8, 0))
        #expect(attribution.scheduledFor == nil)
        #expect(attribution.nearSlot?.time == Self.tod(8), "the switch shows")
    }

    @Test("with the switch off the near take is an extra dose and keeps the switch in view")
    func nearSwitchOff() {
        let attribution = Self.resolve(Self.at(10, 30), countNear: false)
        guard case let .extra(nearSlot) = attribution else {
            Issue.record("expected .extra, got \(attribution)")
            return
        }
        #expect(nearSlot?.time == Self.tod(8))
        #expect(attribution.scheduledFor == nil)
        #expect(attribution.forceSlotInstant == nil)
        #expect(attribution.nearSlot != nil)
    }

    @Test("240 minutes off is still near, 241 is an extra dose without a switch")
    func twoHundredFortyMinuteEdge() {
        if case .late = Self.resolve(Self.at(12, 0)) {} else { Issue.record("12:00 must count as late") }
        let past = Self.resolve(Self.at(12, 1))
        #expect(past == .extra(nearSlot: nil))
        #expect(past.nearSlot == nil)
        if case .late = Self.resolve(Self.at(4, 0)) {} else { Issue.record("04:00 must count as late") }
    }

    // MARK: - Extra, several slots

    @Test("the nearest of several dose times wins")
    func nearestOfSeveral() {
        let times = [Self.tod(8), Self.tod(20)]
        #expect(Self.resolve(Self.at(19, 30), times).scheduledFor == Self.at(20, 0))
        #expect(Self.resolve(Self.at(8, 45), times).scheduledFor == Self.at(8, 0))
        // 14:00 is 6 h from both: an extra dose.
        #expect(Self.resolve(Self.at(14, 0), times) == .extra(nearSlot: nil))
    }

    // MARK: - Skip

    @Test("a skip names the nearest slot that day, however far")
    func skip() {
        let attribution = Self.resolve(Self.at(15, 0), skipped: true)
        guard case let .skip(slot) = attribution else {
            Issue.record("expected .skip, got \(attribution)")
            return
        }
        #expect(slot.instant == Self.at(8, 0))
        #expect(attribution.scheduledFor == Self.at(8, 0))
        #expect(attribution.forceSlotInstant == nil)
    }

    // MARK: - No dose times

    @Test("without dose times a take is an extra dose and there is nothing to skip")
    func noDoseTimes() {
        #expect(Self.resolve(Self.at(8, 0), []) == .extra(nearSlot: nil))
        #expect(Self.resolve(Self.at(8, 0), [], skipped: true) == .noSlot)
        let medication = Self.medication(entries: [])
        #expect(IntakeSlotAttribution.slotTimes(of: medication).isEmpty)
        #expect(!IntakeSlotAttribution.offersSkip(for: medication))
    }

    @Test("an as-needed medication or entry has no dose times")
    func asNeededHasNoTimes() {
        let prnEntry = ScheduleEntry(cadence: .asNeeded, timesOfDay: [], windowStart: Self.tod(8))
        #expect(IntakeSlotAttribution.slotTimes(of: [prnEntry]).isEmpty)
        let prn = Self.medication(entries: [Self.daily([Self.tod(8)])], asNeeded: true)
        #expect(!IntakeSlotAttribution.offersSkip(for: prn))
    }

    @Test("dose times are distinct and sorted; an entry without times uses its window start")
    func slotTimes() {
        let entries = [
            Self.daily([Self.tod(20), Self.tod(8)]),
            Self.daily([Self.tod(8)]),
            ScheduleEntry(cadence: .daily, timesOfDay: [], windowStart: Self.tod(13, 30))
        ]
        #expect(IntakeSlotAttribution.slotTimes(of: entries) == [Self.tod(8), Self.tod(13, 30), Self.tod(20)])
    }

    // MARK: - Day boundary

    @Test("only slots on the take's own day count: 00:15 is not yesterday's 23:30 dose")
    func dayBoundary() {
        let times = [Self.tod(23, 30)]
        let takenAt = Self.at(0, 15, day: 21)
        let nearest = IntakeSlotAttribution.nearestSlot(takenAt: takenAt, times: times, calendar: Self.calendar)
        #expect(nearest?.instant == Self.at(23, 30, day: 21), "the slot instant lies on the take's day")
        #expect(Self.resolve(takenAt, times) == .extra(nearSlot: nil))
        // A skip still names that day's slot.
        #expect(Self.resolve(takenAt, times, skipped: true).scheduledFor == Self.at(23, 30, day: 21))
        // 23:10 the same evening counts on time.
        #expect(Self.resolve(Self.at(23, 10, day: 21), times).scheduledFor == Self.at(23, 30, day: 21))
    }

    // MARK: - Dose

    @Test("the configured dose is the counted slot's schedule dose, else the medication's")
    func configuredDose() {
        let medication = Self.medication(
            dose: "5 mg",
            entries: [Self.daily([Self.tod(8)], dose: "2.5 mg"), Self.daily([Self.tod(20)])]
        )
        let morning = Self.resolve(Self.at(8, 10), [Self.tod(8), Self.tod(20)])
        let evening = Self.resolve(Self.at(20, 10), [Self.tod(8), Self.tod(20)])
        let extra = Self.resolve(Self.at(14, 0), [Self.tod(8), Self.tod(20)])
        #expect(IntakeSlotAttribution.configuredDose(for: medication, attribution: morning) == "2.5 mg")
        #expect(IntakeSlotAttribution.configuredDose(for: medication, attribution: evening) == "5 mg")
        #expect(IntakeSlotAttribution.configuredDose(for: medication, attribution: extra) == "5 mg")
    }

    // MARK: - The request body

    private func encodedBody(_ write: IntakeFormWrite) throws -> [String: Any] {
        let body = MedicationsRepository.MedicationIdIntakeBody(
            scheduledFor: write.scheduledFor,
            takenAt: write.skipped ? nil : write.takenAt,
            skipped: write.skipped,
            idempotencyKey: "k-1",
            doseTaken: write.doseTaken,
            forceSlotInstant: write.forceSlotInstant
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("an on-time take sends scheduledFor and no doseTaken for the planned dose")
    func bodyExact() throws {
        let attribution = Self.resolve(Self.at(8, 20))
        let write = IntakeFormWrite(
            attribution: attribution, takenAt: Self.at(8, 20), skipped: false,
            dose: " 5 mg ", configuredDose: "5 mg"
        )
        #expect(write.scheduledFor == Self.at(8, 0))
        #expect(write.doseTaken == nil, "the untouched planned dose is not a deviation")
        let object = try encodedBody(write)
        #expect(object["scheduledFor"] is String)
        #expect(object["takenAt"] is String)
        #expect(object["forceSlotInstant"] == nil)
        #expect(object["doseTaken"] == nil)
        #expect(object["skipped"] as? Bool == false)
        #expect(object["source"] == nil)
    }

    @Test("a late take sends forceSlotInstant and a deviating dose")
    func bodyLate() throws {
        let attribution = Self.resolve(Self.at(10, 0))
        let write = IntakeFormWrite(
            attribution: attribution, takenAt: Self.at(10, 0), skipped: false,
            dose: "2.5 mg", configuredDose: "5 mg"
        )
        #expect(write.forceSlotInstant == Self.at(8, 0))
        #expect(write.doseTaken == "2.5 mg")
        let object = try encodedBody(write)
        #expect(object["forceSlotInstant"] is String)
        #expect(object["scheduledFor"] == nil)
        #expect(object["doseTaken"] as? String == "2.5 mg")
    }

    @Test("an extra dose sends no slot field")
    func bodyExtra() throws {
        let attribution = Self.resolve(Self.at(10, 0), countNear: false)
        let write = IntakeFormWrite(
            attribution: attribution, takenAt: Self.at(10, 0), skipped: false,
            dose: "", configuredDose: "5 mg"
        )
        #expect(write.doseTaken == nil, "an emptied field records the planned dose")
        let object = try encodedBody(write)
        #expect(object["scheduledFor"] == nil)
        #expect(object["forceSlotInstant"] == nil)
    }

    @Test("a skip sends the skipped slot and never a dose")
    func bodySkip() throws {
        let attribution = Self.resolve(Self.at(9, 30), skipped: true)
        let write = IntakeFormWrite(
            attribution: attribution, takenAt: Self.at(9, 30), skipped: true,
            dose: "2.5 mg", configuredDose: "5 mg"
        )
        #expect(write.doseTaken == nil)
        let object = try encodedBody(write)
        #expect(object["skipped"] as? Bool == true)
        #expect(object["scheduledFor"] is String)
        #expect(object["takenAt"] == nil)
        #expect(object["doseTaken"] == nil)
    }

    // MARK: - Words

    @MainActor
    @Test("the line under the fields says something for every case but a skip without a slot")
    func lines() {
        let slot = IntakeSlotAttribution.Slot(time: Self.tod(8), instant: Self.at(8, 0), gapMinutes: 0)
        #expect(MedicationIntakeForm.line(for: .slot(slot)) != nil)
        #expect(MedicationIntakeForm.line(for: .late(slot)) != nil)
        #expect(MedicationIntakeForm.line(for: .skip(slot)) != nil)
        #expect(MedicationIntakeForm.line(for: .extra(nearSlot: nil)) != nil)
        #expect(MedicationIntakeForm.line(for: .noSlot) == nil)
    }

    // MARK: - Update path: a medication from an older cache

    /// A cache blob from before `entries` existed, with no times: the
    /// medication decodes with no dose times, so the form offers Taken only.
    @Test("an older cached medication without dose times only offers Taken")
    func olderCacheWithoutDoseTimes() throws {
        let schedule = try JSONDecoder().decode(MedicationSchedule.self, from: Data(#"{"times":[]}"#.utf8))
        let medication = Medication(id: "med-old", name: "Old", dose: "1 tab", schedule: schedule)
        #expect(!IntakeSlotAttribution.offersSkip(for: medication))
        // A take is recorded as an extra dose, without a slot field.
        let attribution = IntakeSlotAttribution.resolve(
            takenAt: Self.at(8, 0),
            times: IntakeSlotAttribution.slotTimes(of: medication),
            skipped: false,
            countNear: true,
            calendar: Self.calendar
        )
        #expect(attribution == .extra(nearSlot: nil))
        #expect(attribution.scheduledFor == nil && attribution.forceSlotInstant == nil)
    }

    /// The same older blob with times re-derives a legacy entry, so its dose
    /// time still counts and Skip is offered.
    @Test("an older cached medication with times still offers Skip")
    func olderCacheWithTimes() throws {
        let schedule = try JSONDecoder().decode(
            MedicationSchedule.self,
            from: Data(#"{"times":[{"hour":8,"minute":0}]}"#.utf8)
        )
        let medication = Medication(id: "med-old", name: "Old", dose: "1 tab", schedule: schedule)
        #expect(IntakeSlotAttribution.offersSkip(for: medication))
        #expect(IntakeSlotAttribution.slotTimes(of: medication) == [Self.tod(8)])
    }
}
