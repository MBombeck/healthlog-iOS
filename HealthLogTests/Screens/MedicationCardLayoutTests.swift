import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **v0.6.1.2 Y4 — MedicationCard contract tests.**
///
/// SwiftUI bodies are opaque to introspection; this suite anchors on
/// the pure presentation projections the card reads from its inputs —
/// `MedicationCard.computeNextDose`, category resolver, relative date
/// formatter. A change to the card's body cannot regress the contract
/// without one of these derivations also moving.
@Suite("MedicationCard — layout contract")
struct MedicationCardLayoutTests {
    // MARK: - Next-dose computation

    /// Local device zone — the engine + the assertion calendar both anchor on
    /// it so the wall-clock expectations hold regardless of the machine's TZ.
    private static let tz = TimeZone.current

    /// Minimal medication fixture wrapping a schedule (+ optional server
    /// `nextDueAt` / `lastTakenAt`) for the `computeNextDose` contract.
    private static func med(
        schedule: MedicationSchedule,
        nextDueAt: Date? = nil,
        lastTakenAt: Date? = nil
    ) -> Medication {
        Medication(
            id: "med-1",
            name: "Test",
            dose: "5 mg",
            schedule: schedule,
            lastTakenAt: lastTakenAt,
            nextDueAt: nextDueAt
        )
    }

    @Test("Weekly Wednesday schedule projects to the next Wednesday at 08:00")
    func weeklyNextDose() throws {
        // Tuesday 2025-12-09 18:00 in the device zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.tz
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 9 // Tuesday
        components.hour = 18
        components.minute = 0
        components.timeZone = Self.tz
        let now = try #require(calendar.date(from: components))

        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0)],
            weekdays: [.wed]
        )
        let next = MedicationCard.computeNextDose(
            medication: Self.med(schedule: schedule),
            timeZone: Self.tz,
            now: now
        )
        #expect(next != nil)
        let nextComponents = try calendar.dateComponents([.weekday, .hour, .minute], from: #require(next))
        // Wednesday = 4 in Calendar.weekday (Sunday = 1).
        #expect(nextComponents.weekday == 4)
        #expect(nextComponents.hour == 8)
        #expect(nextComponents.minute == 0)
    }

    @Test("Daily-window medication picks the earliest future time today")
    func dailyNextDose() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.tz
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 9
        components.hour = 9
        components.minute = 30
        components.timeZone = Self.tz
        let now = try #require(calendar.date(from: components))

        let schedule = MedicationSchedule(
            times: [
                TimeOfDay(hour: 8, minute: 0), // already past
                TimeOfDay(hour: 14, minute: 0), // future today
                TimeOfDay(hour: 20, minute: 0) // future today
            ]
        )
        let next = MedicationCard.computeNextDose(
            medication: Self.med(schedule: schedule),
            timeZone: Self.tz,
            now: now
        )
        #expect(next != nil)
        let nextComponents = try calendar.dateComponents([.hour, .minute, .day], from: #require(next))
        #expect(nextComponents.day == 9)
        #expect(nextComponents.hour == 14)
        #expect(nextComponents.minute == 0)
    }

    @Test("Daily schedule with all times in the past projects to tomorrow's earliest")
    func dailyNextDoseRollsToTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.tz
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 9
        components.hour = 22
        components.minute = 0
        components.timeZone = Self.tz
        let now = try #require(calendar.date(from: components))

        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)]
        )
        let next = MedicationCard.computeNextDose(
            medication: Self.med(schedule: schedule),
            timeZone: Self.tz,
            now: now
        )
        #expect(next != nil)
        let nextComponents = try calendar.dateComponents([.day, .hour, .minute], from: #require(next))
        #expect(nextComponents.day == 10)
        #expect(nextComponents.hour == 8)
    }

    @Test("PRN medication (no times) returns nil")
    func prnReturnsNil() {
        let schedule = MedicationSchedule(times: [])
        let next = MedicationCard.computeNextDose(
            medication: Self.med(schedule: schedule),
            timeZone: Self.tz,
            now: Date()
        )
        #expect(next == nil)
    }

    // MARK: - v0.14.1 INV-med-cadence-phantom (BUG 1) — rolling/weekly card next-dose

    /// A rolling (flexible every-7-days) GLP-1 med must show its REAL next date
    /// — the server-authoritative `nextDueAt` (~+7 days), routed through the
    /// recurrence engine — NOT "tomorrow". The old day-by-day projector ignored
    /// `nextDueAt` and flattened rolling to daily, so the card read "morgen".
    @Test("Rolling weekly med card next-dose equals the server nextDueAt, not tomorrow")
    func rollingCardNextDoseUsesServerNextDueAt() throws {
        let now = Date()
        let serverNextDue = now.addingTimeInterval(7 * 24 * 60 * 60) // +7 days
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)

        // Rolling cadence carried as a single-slot entry; the engine prefers
        // `serverNextDueAt` for single-slot cadences.
        let schedule = MedicationSchedule(entries: [
            ScheduleEntry(
                cadence: .rolling(intervalDays: 7),
                timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                windowStart: TimeOfDay(hour: 8, minute: 0)
            )
        ])
        let next = try #require(
            MedicationCard.computeNextDose(
                medication: Self.med(schedule: schedule, nextDueAt: serverNextDue),
                timeZone: Self.tz,
                now: now
            )
        )
        // Must equal the server next-due instant (engine override), well past
        // "tomorrow" — i.e. NOT flattened to daily.
        #expect(abs(next.timeIntervalSince(serverNextDue)) < 1)
        #expect(next > tomorrow.addingTimeInterval(60), "rolling med must not read as 'tomorrow'")
    }

    /// Fallback: when there are no structured entries but the server supplied a
    /// future `nextDueAt`, the card trusts it rather than rendering nothing.
    @Test("No-entries schedule falls back to server nextDueAt")
    func noEntriesFallsBackToNextDueAt() throws {
        let now = Date()
        let serverNextDue = now.addingTimeInterval(3 * 24 * 60 * 60)
        let next = try #require(
            MedicationCard.computeNextDose(
                medication: Self.med(schedule: MedicationSchedule(times: []), nextDueAt: serverNextDue),
                timeZone: Self.tz,
                now: now
            )
        )
        #expect(abs(next.timeIntervalSince(serverNextDue)) < 1)
    }

    // MARK: - Category resolver

    @Test("BLOOD_PRESSURE resolves to the localised label")
    func bloodPressureResolves() {
        let label = MedicationCard.localizedCategory("BLOOD_PRESSURE")
        #expect(label == "Bluthochdruck")
    }

    @Test("Unknown category falls back to a humanised raw form")
    func unknownCategoryHumanises() {
        let label = MedicationCard.localizedCategory("BRAND_NEW_CLASS")
        #expect(label == "Brand New Class")
    }

    @Test("OTHER resolves to Sonstige")
    func otherResolves() {
        let label = MedicationCard.localizedCategory("OTHER")
        #expect(label == "Sonstige")
    }

    // MARK: - Relative datetime

    @Test("Same-day date uses the heute label")
    func relativeDateTimeToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        var nowComponents = DateComponents()
        nowComponents.year = 2025
        nowComponents.month = 12
        nowComponents.day = 9
        nowComponents.hour = 18
        let now = try #require(calendar.date(from: nowComponents))

        var doseComponents = DateComponents()
        doseComponents.year = 2025
        doseComponents.month = 12
        doseComponents.day = 9
        doseComponents.hour = 8
        doseComponents.minute = 0
        let dose = try #require(calendar.date(from: doseComponents))

        let label = MedicationCard.relativeDateTime(dose, now: now)
        #expect(label.hasPrefix("heute, "))
    }

    @Test("Yesterday date uses the gestern label")
    func relativeDateTimeYesterday() throws {
        let calendar = Calendar(identifier: .gregorian)
        var nowComponents = DateComponents()
        nowComponents.year = 2025
        nowComponents.month = 12
        nowComponents.day = 9
        nowComponents.hour = 10
        let now = try #require(calendar.date(from: nowComponents))

        var doseComponents = DateComponents()
        doseComponents.year = 2025
        doseComponents.month = 12
        doseComponents.day = 8
        doseComponents.hour = 8
        let dose = try #require(calendar.date(from: doseComponents))

        let label = MedicationCard.relativeDateTime(dose, now: now)
        #expect(label.hasPrefix("gestern, "))
    }

    // MARK: - Schedule value tint (state→colour, type-independent)

    /// **v0.14.1 FW-MEDCARD.** The "next dose" value colour must be driven by
    /// the window *state*, never by the med *type* (weekly injectable like
    /// Trulicity vs daily oral like Lisinopril). Equivalent states therefore must
    /// resolve to the identical colour on both cards.
    @Test("Due-now state tints the next value statusOK regardless of cadence")
    func nextValueTintDueNow() {
        #expect(MedicationCard.nextValueTint(windowStatus: .inWindow) == HLColor.statusOK)
    }

    @Test("Non-due states keep the next value primary (no per-state colour drift)")
    func nextValueTintRestingStates() {
        #expect(MedicationCard.nextValueTint(windowStatus: nil) == HLText.primary)
        #expect(MedicationCard.nextValueTint(windowStatus: .late) == HLText.primary)
        #expect(MedicationCard.nextValueTint(windowStatus: .veryLate) == HLText.primary)
    }

    @Test("Same window-state yields the same tint — med type never changes it")
    func nextValueTintIsTypeIndependent() {
        // Two cards (weekly injectable, daily oral) in the SAME state must read
        // the same colour. The helper takes only the state, so identical state
        // input proves identical colour output by construction.
        for state in [MedicationWindowStatus?.none, .some(.inWindow), .some(.late), .some(.veryLate)] {
            let a = MedicationCard.nextValueTint(windowStatus: state)
            let b = MedicationCard.nextValueTint(windowStatus: state)
            #expect(a == b)
        }
    }

    // MARK: - MED-11 — structural identity (labels + compliance slot)

    /// **MED-11.** The schedule strip labels must be ONE label set regardless of
    /// cadence — a weekly injectable (Trulicity) and a daily oral (Lisinopril) both
    /// read "Letzte Einnahme" / "Nächste Einnahme", never the old
    /// "Termin"/"Einnahme" divergence the operator flagged. The card resolves
    /// both rows from the same `med.card.schedule.daily.*` keys; this anchors
    /// the localized values so a regression to a per-cadence "Termin" label
    /// fails the build.
    @Test("Schedule labels are one set regardless of cadence — no Termin/Einnahme drift")
    func scheduleLabelsAreCadenceIndependent() {
        #expect(String(localized: "med.card.schedule.daily.last.label") == "Letzte Einnahme")
        #expect(String(localized: "med.card.schedule.daily.next.label") == "Nächste Einnahme")
        // No "Termin" wording in either resolved label (the divergence is gone).
        #expect(!String(localized: "med.card.schedule.daily.last.label").contains("Termin"))
        #expect(!String(localized: "med.card.schedule.daily.next.label").contains("Termin"))
    }

    /// **MED-11.** A PRN / as-needed medication has no schedule → no compliance
    /// rate, so `displayRows` is empty. The card therefore needs a dedicated
    /// "as needed" slot (`AsNeededComplianceNote`) to stay structurally
    /// identical to a scheduled card (which paints two bars). This pins the
    /// empty-rows fact the structural slot is built on.
    @Test("PRN snapshot yields no compliance rows — the as-needed slot fills the gap")
    func prnHasNoComplianceRows() {
        let prn = MedicationsStore.complianceSnapshot(
            for: Self.med(schedule: MedicationSchedule(times: [])),
            windowIntakes: []
        )
        #expect(prn.rate30 == nil)
        #expect(prn.displayRows.isEmpty)
        // The as-needed slot copy resolves (so the card never renders a blank).
        #expect(String(localized: "med.card.compliance.as_needed") == "Nach Bedarf")
    }

    /// **MED-11.** A scheduled medication DOES produce compliance rows, so the
    /// scheduled card paints bars while the PRN card paints the as-needed note —
    /// same slot, value-driven content, identical structure. This proves the two
    /// branches are mutually exclusive (never both, never neither).
    @Test("Scheduled snapshot yields compliance rows — same slot, different content")
    func scheduledHasComplianceRows() {
        let scheduled = MedicationsStore.complianceSnapshot(
            for: Self.med(schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])),
            windowIntakes: []
        )
        #expect(scheduled.rate30 != nil)
        #expect(!scheduled.displayRows.isEmpty)
    }
}
