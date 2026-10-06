import Foundation
@testable import HealthLog
import Testing

/// **v1.39.1 (#1033) — a medication kept as a record plans nothing.**
///
/// Server v1.39.1 adds `trackIntake` (default true). With it off the medication
/// keeps its dose, dates and schedule as information, but nothing is ever due:
/// no reminder on any channel, no projected slot, no entry on the doses card,
/// no adherence figure. The wire serves such a medication with `schedules: []`
/// and the stored rows in `recordedSchedules`
/// (`src/lib/medications/intake-tracking.ts` `scheduleWireFields`).
///
/// Fixtures follow `MedicationListEntry` in `docs/api/openapi.yaml` on
/// tag `v1.39.1` (every required key; unchanged since the pre-release state
/// they were first taken from). The record-only case is the
/// server's own "Atorvastatin 20, recorded daily at 21:00" from
/// `src/app/api/medications/[id]/__tests__/route.test.ts`.
@Suite("v1.39.1 #1033 — trackIntake: a record plans nothing")
struct MedicationTrackIntakeV1391Tests {
    // MARK: - Fixtures (v1.39.1 wire shape)

    static func schedule(_ time: String) -> String {
        """
        {"id":"sch-1","medicationId":"med-rec","windowStart":"\(time)","windowEnd":"\(time)","label":null,\
        "dose":null,"unitsPerDose":null,"resolvedUnitsPerDose":1,"daysOfWeek":null,"timesOfDay":["\(time)"],\
        "reminderGraceMinutes":null,"rrule":"FREQ=DAILY","rollingIntervalDays":null,"scheduleType":"SCHEDULED",\
        "cyclicOnWeeks":null,"cyclicOffWeeks":null}
        """
    }

    /// `trackIntake` → the flag and the schedule fields as the server shapes
    /// them; `nil` drops `trackIntake` and `recordedSchedules` entirely (a
    /// server older than v1.39.1).
    static func medicationJSON(
        id: String = "med-rec",
        trackIntake: Bool?,
        schedules: [String],
        recorded: [String]? = nil,
        asNeeded: Bool = false,
        nextDueAt: String = "null"
    ) -> String {
        let flag = trackIntake.map { #""trackIntake":\#($0),"# } ?? ""
        let recordedKey = recorded.map { #""recordedSchedules":[\#($0.joined(separator: ","))],"# } ?? ""
        return """
        {"id":"\(id)","name":"Atorvastatin 20","dose":"20 mg","treatmentClass":"GENERIC","dosesPerUnit":null,\
        "unitsPerDose":1,"reorderLeadDays":null,"active":true,"notificationsEnabled":true,\
        "liveActivityEnabled":true,"criticalAlarmEnabled":true,"atcCode":null,"rxNormCode":null,"pausedAt":null,\
        "snoozedUntil":null,"nextDueAt":\(nextDueAt),"nextDueOverdue":false,"startsOn":null,"endsOn":null,\
        "oneShot":false,"asNeeded":\(asNeeded),\(flag)"createdAt":"2026-09-01T08:00:00.000Z",\
        "updatedAt":"2026-09-25T08:00:00.000Z","schedules":[\(schedules.joined(separator: ","))],\(recordedKey)\
        "category":"OTHER","externalSource":null,"lastTakenAt":null,"todayEventCount":0,\
        "stockUnitsRemaining":null,"stockDosesRemaining":null,"runwayDays":null}
        """
    }

    static func decode(_ json: String) throws -> Medication {
        try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
    }

    /// The record-only medication exactly as v1.39.1 serves it.
    static func recordOnly(id: String = "med-rec") throws -> Medication {
        try decode(medicationJSON(id: id, trackIntake: false, schedules: [], recorded: [schedule("21:00")]))
    }

    /// The same medication while tracked (v1.39.1 shape).
    static func tracked(id: String = "med-rec") throws -> Medication {
        try decode(medicationJSON(
            id: id, trackIntake: true, schedules: [schedule("21:00")],
            nextDueAt: #""2026-09-25T19:00:00.000Z""#
        ))
    }

    // MARK: - Decode

    @Test("v1.39.1 record: flag decoded, no live schedule, stored schedule kept as information")
    func decodesRecordOnly() throws {
        let med = try Self.recordOnly()
        #expect(med.trackIntake == false)
        #expect(!med.tracksIntake)
        #expect(med.schedule.entries.isEmpty)
        #expect(med.displaySchedule.times == [TimeOfDay(hour: 21, minute: 0)])
        #expect(med.nextDueAt == nil)
    }

    @Test("an older server (no trackIntake, no recordedSchedules) reads as tracked, schedule intact")
    func olderServerIsTracked() throws {
        let med = try Self.decode(Self.medicationJSON(trackIntake: nil, schedules: [Self.schedule("08:00")]))
        #expect(med.trackIntake == nil)
        #expect(med.tracksIntake)
        #expect(med.recordedSchedule == nil)
        #expect(med.schedule.times == [TimeOfDay(hour: 8, minute: 0)])
        #expect(med.displaySchedule == med.schedule)
    }

    @Test("a record whose row still carries schedules plans none of them (defence in depth)")
    func recordWithSchedulesPlansNothing() throws {
        let med = try Self.decode(Self.medicationJSON(
            trackIntake: false, schedules: [Self.schedule("21:00")], recorded: [Self.schedule("21:00")],
            nextDueAt: #""2026-09-25T19:00:00.000Z""#
        ))
        #expect(med.schedule.entries.isEmpty)
        #expect(med.nextDueAt == nil)
        #expect(med.displaySchedule.times == [TimeOfDay(hour: 21, minute: 0)])
    }

    @Test("the flag survives the domain round trip through the SWR cache")
    func domainCodableRoundTrip() throws {
        let med = try Self.recordOnly()
        let back = try JSONDecoder().decode(Medication.self, from: JSONEncoder().encode(med))
        #expect(back.trackIntake == false)
        #expect(back.recordedSchedule?.times == [TimeOfDay(hour: 21, minute: 0)])
    }

    // MARK: - No lock-screen / alarm / Live Activity / derived dose

    @Test("no critical alarm is eligible for a record, even with the alarm switched on")
    func noAlarm() throws {
        let rec = try Self.recordOnly()
        // Defence in depth: give the record a live schedule the server never sends.
        let withSchedule = rec.replacingSchedule(rec.displaySchedule)
        #expect(!CriticalMedAlarmRouting.isAlarmEligible(
            medication: withSchedule, alarmEnabled: { _ in true }, authorized: true, osAvailable: true
        ))
        #expect(try CriticalMedAlarmRouting.isAlarmEligible(
            medication: Self.tracked(), alarmEnabled: { _ in true }, authorized: true, osAvailable: true
        ))
    }

    @Test("no Live Activity surfaces for a record")
    func noLiveActivity() throws {
        let rec = try Self.recordOnly()
        // 30 min before the 21:00 slot: inside the two-hour lead window.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-25T20:30:00Z"))
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [rec.replacingSchedule(rec.displaySchedule)],
            intakes: [],
            now: now,
            calendar: Self.utc
        )
        #expect(dose == nil)
        // Control: the same medication while tracked does surface.
        let tracked = try MedicationLiveActivityPlan.doseToSurface(
            medications: [Self.tracked()], intakes: [], now: now, calendar: Self.utc
        )
        #expect(tracked?.medicationId == "med-rec")
    }

    @Test("today's rows of a record leave the doses card, ring, widget and watch; tracked rows stay")
    func derivedIntakesDropRecord() throws {
        let rec = try Self.recordOnly(id: "med-rec")
        let other = try Self.tracked(id: "med-live")
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-25T20:00:00Z"))
        let rows = [
            Self.intake(id: "i-rec", medicationId: "med-rec", at: "2026-09-25T19:00:00Z"),
            Self.intake(id: "i-live", medicationId: "med-live", at: "2026-09-25T19:00:00Z")
        ]
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: rows, medications: [rec, other], now: now, calendar: Self.utc
        )
        #expect(derived.contains { $0.id == "i-live" })
        #expect(!derived.contains { $0.medicationId == "med-rec" })

        let widget = WidgetSnapshot.make(medications: [rec, other], derivedIntakes: rows, now: now, calendar: Self.utc)
        #expect(widget.compliance.scheduled == 1)
        let watch = WatchSnapshot.make(
            medications: [rec, other], derivedIntakes: rows, recentMoods: [], signedIn: true, now: now, calendar: Self.utc
        )
        #expect(watch.doses.map(\.id) == ["i-live"])
        #expect(watch.scheduledCount == 1)
    }

    @Test("quick intake and the card offer no intake for a record (PRN record included)")
    func noIntakeButtons() throws {
        let rec = try Self.recordOnly()
        let prnRecord = try Self.decode(Self.medicationJSON(
            id: "med-prn", trackIntake: false, schedules: [], recorded: [], asNeeded: true
        ))
        let options = MedicationQuickIntakeOptions.resolve(
            medications: [rec, prnRecord],
            intakes: [Self.intake(id: "i-rec", medicationId: "med-rec", at: "2026-09-25T19:00:00Z")],
            now: .distantFuture
        )
        #expect(options.isEmpty)
        #expect(!rec.allowsManualDoseLogging)
        #expect(MedicationCardActions.resolve(medication: rec, now: .now).deviatingDose == nil)
        #expect(try Self.tracked().allowsManualDoseLogging)
    }

    @Test("the card's next line says 'not tracked' instead of reading the stored schedule as a plan")
    func cardNextLine() throws {
        let strip = try MedicationCardSchedule.resolve(
            medication: Self.recordOnly(), lastTakenAt: nil, scheduleSummary: "21:00",
            windowStatus: nil, nextDose: nil, now: .now
        )
        #expect(strip.next?.value == String(localized: "med.card.schedule.not_tracked"))
    }

    // MARK: - Helpers

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func intake(id: String, medicationId: String, at iso: String) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medicationId,
            scheduledAt: ISO8601DateFormatter().date(from: iso) ?? .distantPast,
            takenAt: nil,
            status: .pending,
            snoozedUntil: nil
        )
    }
}

#if canImport(SpeziScheduler) && canImport(UserNotifications)
    /// **The update path (#1033):** reminders armed while the medication was
    /// tracked are REMOVED on the next reconcile once the server reports it as a
    /// record. `reconcile` deletes every stored `med-` task its desired set does
    /// not name; these tests pin both halves without a live `Scheduler`.
    @Suite("v1.39.1 #1033 — local reminders of a record are removed on the next reconcile")
    @MainActor
    struct MedicationTrackIntakeSchedulerTests {
        @Test("a tracked medication arms tasks; the same medication as a record arms none")
        func desiredSet() throws {
            let now = Date()
            #expect(try !MedicationsSchedulerModule.desiredTaskIDs(
                for: [MedicationTrackIntakeV1391Tests.tracked()], now: now
            ).isEmpty)
            #expect(try MedicationsSchedulerModule.desiredTaskIDs(
                for: [MedicationTrackIntakeV1391Tests.recordOnly()], now: now
            ).isEmpty)
        }

        @Test("reminders armed before the switch are purged; other tasks are left alone")
        func armedRemindersArePurged() throws {
            let now = Date()
            let armed = try MedicationsSchedulerModule.desiredTaskIDs(
                for: [MedicationTrackIntakeV1391Tests.tracked()], now: now
            )
            let afterSwitch = try MedicationsSchedulerModule.desiredTaskIDs(
                for: [MedicationTrackIntakeV1391Tests.recordOnly()], now: now
            )
            let purged = MedicationsSchedulerModule.orphanTaskIDs(
                existing: armed.union(["questionnaire-daily"]), desired: afterSwitch
            )
            #expect(purged == armed)
        }

        @Test("even a record row that still carries schedules plans no reminder")
        func recordWithScheduleRowPlansNothing() throws {
            let rec = try MedicationTrackIntakeV1391Tests.recordOnly()
            #expect(!MedicationsSchedulerModule.plansReminders(for: rec.replacingSchedule(rec.displaySchedule)))
        }
    }
#endif
