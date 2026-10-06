import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **R1 — server v1.39.4 `courseStatus` / `intakeActionable` (#1040).**
///
/// The server publishes, on `GET /api/medications` and `/{id}`, where today
/// sits in the course (`UPCOMING` / `CURRENT` / `ENDED`, calendar days on the
/// account's clock, both ends inclusive) and whether Taken / Skip are offered
/// (`active && trackIntake && courseStatus == CURRENT`). The app reads both and
/// re-derives neither: a missing field (older server) is "actionable", a
/// missing status is "no badge". Fixtures follow `MedicationListEntry` in
/// `docs/api/openapi.yaml` at tag `v1.39.4`.
///
/// The fixtures deliberately carry NO `endsOn` on the ended medication: the
/// local engine would still project today's dose, so every gate below can only
/// be closed by the server's field — which is the contract ("do not re-derive
/// it from startsOn / endsOn").
@Suite("v1.39.4 #1040 — courseStatus and intakeActionable gate every dose action")
struct MedicationCourseStatusV1394Tests {
    static func json(
        id: String = "med-course",
        courseStatus: String?,
        intakeActionable: Bool?,
        startsOn: String = "null",
        asNeeded: Bool = false
    ) -> String {
        let status = courseStatus.map { #""courseStatus":"\#($0)","# } ?? ""
        let actionable = intakeActionable.map { #""intakeActionable":\#($0),"# } ?? ""
        let schedules = asNeeded ? "" : MedicationTrackIntakeV1391Tests.schedule("08:00")
        return """
        {"id":"\(id)","name":"Amoxicillin","dose":"500 mg","treatmentClass":"GENERIC","dosesPerUnit":null,\
        "unitsPerDose":1,"active":true,"notificationsEnabled":true,"liveActivityEnabled":true,\
        "criticalAlarmEnabled":false,"pausedAt":null,"snoozedUntil":null,"nextDueAt":null,\
        "nextDueOverdue":false,"startsOn":\(startsOn),"endsOn":null,"oneShot":false,"asNeeded":\(asNeeded),\
        "trackIntake":true,\(status)\(actionable)"createdAt":"2026-09-01T08:00:00.000Z",\
        "schedules":[\(schedules)],"category":"ANTIBIOTIC","externalSource":null,"lastTakenAt":null,\
        "todayEventCount":0,"stockDosesRemaining":null,"runwayDays":null}
        """
    }

    static func decode(_ json: String) throws -> Medication {
        try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: Data(json.utf8)).toDomain()
    }

    static func ended() throws -> Medication {
        try decode(json(courseStatus: "ENDED", intakeActionable: false))
    }

    static func current() throws -> Medication {
        try decode(json(courseStatus: "CURRENT", intakeActionable: true))
    }

    static func older() throws -> Medication {
        try decode(json(courseStatus: nil, intakeActionable: nil))
    }

    static func pending(_ id: String, medicationId: String = "med-course", at: Date) -> MedicationIntake {
        MedicationIntake(id: id, medicationId: medicationId, scheduledAt: at, takenAt: nil, status: .pending, snoozedUntil: nil)
    }

    // MARK: - Decoding

    @Test("both fields decode; an older server reads as actionable with no status")
    func decoding() throws {
        let ended = try Self.ended()
        #expect(ended.courseStatus == .ended)
        #expect(ended.intakeActionable == false)
        #expect(!ended.isIntakeActionable)
        #expect(!ended.offersIntakeActions)

        let older = try Self.older()
        #expect(older.courseStatus == nil)
        #expect(older.intakeActionable == nil)
        #expect(older.isIntakeActionable)
        #expect(older.offersIntakeActions)

        let upcoming = try Self.decode(Self.json(courseStatus: "UPCOMING", intakeActionable: false))
        #expect(upcoming.courseStatus == .upcoming)
    }

    @Test("a status word this build does not know keeps the medication and changes nothing")
    func unknownStatus() throws {
        let med = try Self.decode(Self.json(courseStatus: "zz_from_the_future", intakeActionable: true))
        #expect(med.courseStatus == .unknown)
        #expect(med.offersIntakeActions)
        #expect(MedicationCourseBadge.resolve(med) == nil)
    }

    @Test("the fields survive the SWR cache round trip of the domain medication")
    func cacheRoundTrip() throws {
        let ended = try Self.ended()
        let data = try JSONEncoder().encode(ended)
        let back = try JSONDecoder().decode(Medication.self, from: data)
        #expect(back.courseStatus == .ended)
        #expect(back.intakeActionable == false)
    }

    // MARK: - Every surface that offers Taken / Skip

    @Test("card buttons and the deviating-dose long press are withheld")
    func cardActions() throws {
        #expect(try !Self.ended().allowsManualDoseLogging)
        #expect(try MedicationCardActions.resolve(medication: Self.ended(), now: .now).deviatingDose == nil)
        #expect(try Self.current().allowsManualDoseLogging)
        #expect(try Self.older().allowsManualDoseLogging)
    }

    @Test("quick intake and take-all offer no dose of a not-actionable medication")
    func quickIntakeAndTakeAll() throws {
        let now = Date()
        let open = Self.pending("i1", at: now.addingTimeInterval(-600))
        let ended = try MedicationQuickIntakeOptions.resolve(medications: [Self.ended()], intakes: [open], now: now)
        #expect(ended.due.isEmpty)
        let current = try MedicationQuickIntakeOptions.resolve(medications: [Self.current()], intakes: [open], now: now)
        #expect(current.due.map(\.intake.id) == ["i1"])
        // PRN row of the quick-intake sheet.
        let prn = try Self.decode(Self.json(courseStatus: "ENDED", intakeActionable: false, asNeeded: true))
        #expect(MedicationQuickIntakeOptions.resolve(medications: [prn], intakes: [], now: now).asNeeded.isEmpty)
    }

    @Test("dose card, ring, widget and watch rows: open rows dropped, resolved rows kept")
    func todayRows() throws {
        let now = Date()
        let taken = MedicationIntake(
            id: "t", medicationId: "med-course", scheduledAt: now.addingTimeInterval(-3600),
            takenAt: now.addingTimeInterval(-3500), status: .taken, snoozedUntil: nil
        )
        let open = Self.pending("p", at: now.addingTimeInterval(-60))
        let kept = try MedicationIntake.excludingUntrackedMedications([taken, open], medications: [Self.ended()])
        #expect(kept.map(\.id) == ["t"])
        let untouched = try MedicationIntake.excludingUntrackedMedications([taken, open], medications: [Self.older()])
        #expect(untouched.map(\.id) == ["t", "p"])

        let widget = try WidgetSnapshot.make(medications: [Self.ended()], derivedIntakes: [taken, open], now: now)
        #expect(widget.nextDose == nil)
        let watch = try WatchSnapshot.make(
            medications: [Self.ended()], derivedIntakes: [open], recentMoods: [], signedIn: true, now: now
        )
        #expect(watch.doses.allSatisfy { !$0.isActionable })
        #expect(watch.doses.isEmpty)
    }

    @Test("no placeholder dose is synthesised for a not-actionable medication")
    func noSynthesisedDose() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 7)))
        let endedMedication = try Self.ended()
        let ended = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [], medications: [endedMedication], now: now, calendar: calendar
        )
        #expect(ended.isEmpty)
        let currentMedication = try Self.current()
        let current = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [], medications: [currentMedication], now: now, calendar: calendar
        )
        #expect(current.count == 1)
    }

    @Test("Live Activity and next-dose widget surface no dose of a not-actionable medication")
    func liveActivity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: .now)
        let now = calendar.date(byAdding: .minute, value: 7 * 60 + 50, to: today)!
        #expect(try MedicationLiveActivityPlan.doseToSurface(
            medications: [Self.ended()], intakes: [], now: now, calendar: calendar
        ) == nil)
        #expect(try MedicationLiveActivityPlan.doseToSurface(
            medications: [Self.current()], intakes: [], now: now, calendar: calendar
        ) != nil)
    }

    // MARK: - Badge

    @Test("ENDED reads Beendet, UPCOMING names its start day, CURRENT and older servers show none")
    func badge() throws {
        #expect(try MedicationCourseBadge.resolve(Self.ended()) == .ended)
        #expect(MedicationCourseBadge.ended.title == String(localized: "medications.course.ended.badge"))
        #expect(MedicationCourseBadge.ended.title == "Beendet")
        #expect(try MedicationCourseBadge.resolve(Self.current()) == nil)
        #expect(try MedicationCourseBadge.resolve(Self.older()) == nil)

        let upcoming = try Self.decode(Self.json(
            courseStatus: "UPCOMING", intakeActionable: false, startsOn: #""2026-10-14""#
        ))
        let badge = try #require(MedicationCourseBadge.resolve(upcoming))
        // The start day is printed as the calendar day it names in every zone.
        #expect(badge.title.hasPrefix("Beginnt am"))
        #expect(badge.title.contains("14"))
    }
}
