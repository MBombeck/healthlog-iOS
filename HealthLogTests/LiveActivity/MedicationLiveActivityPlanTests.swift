import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.8.4 WWIDGET-1** — pins the pure Live-Activity lifecycle decisions
/// (`MedicationLiveActivityPlan`). These are the start / update / end
/// decisions the `@MainActor` controller is a thin shell over — covering
/// them here keeps the lifecycle logic verifiable without a live
/// ActivityKit surface.
@Suite("MedicationLiveActivityPlan — dose surfacing decisions")
struct MedicationLiveActivityPlanTests {
    /// Fixed reference clock: 2026-05-29 08:00 local.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 29
        comps.hour = 8
        comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    private func med(
        id: String = "med-1",
        name: String = "Vitamin D",
        dose: String = "1000 IE",
        times: [TimeOfDay],
        active: Bool = true,
        notificationsEnabled: Bool = true
    ) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: dose,
            schedule: MedicationSchedule(times: times),
            notificationsEnabled: notificationsEnabled,
            active: active
        )
    }

    @Test("Surfaces a dose due inside the 2h lead window")
    func surfacesDoseInLeadWindow() {
        // Dose at 09:00, now 08:00 → 1h out, inside the 2h lead window.
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose != nil)
        #expect(dose?.medicationId == "med-1")
        #expect(dose?.medicationName == "Vitamin D")
        #expect(dose?.doseText == "1000 IE")
    }

    @Test("Does not surface a dose far outside the lead window")
    func ignoresDistantDose() {
        // Dose at 22:00, now 08:00 → 14h out, well beyond the 2h window.
        let medication = med(times: [TimeOfDay(hour: 22, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose == nil)
    }

    @Test("Surfaces a recently-overdue dose still inside the grace window")
    func surfacesOverdueDose() {
        // Dose at 07:00, now 08:00 → 1h overdue, inside the 3h grace.
        let medication = med(times: [TimeOfDay(hour: 7, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose != nil)
    }

    @Test("Does not surface a long-overdue dose past the grace window")
    func ignoresLongOverdueDose() {
        // Dose at 03:00, now 08:00 → 5h overdue, beyond the 3h grace.
        let medication = med(times: [TimeOfDay(hour: 3, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose == nil)
    }

    @Test("Skips an already-taken dose")
    func skipsTakenDose() throws {
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let scheduled = try #require(Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: now
        ))
        let intake = MedicationIntake(
            id: "i1",
            medicationId: "med-1",
            scheduledAt: scheduled,
            takenAt: now,
            status: .taken
        )
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [intake],
            now: now
        )
        #expect(dose == nil)
    }

    @Test("Skips inactive / notifications-disabled medications")
    func skipsInactiveOrSilenced() {
        let inactive = med(id: "a", times: [TimeOfDay(hour: 9, minute: 0)], active: false)
        let silenced = med(id: "b", times: [TimeOfDay(hour: 9, minute: 0)], notificationsEnabled: false)
        #expect(
            MedicationLiveActivityPlan.doseToSurface(
                medications: [inactive, silenced],
                intakes: [],
                now: now
            ) == nil
        )
    }

    @Test("Picks the soonest of several in-window doses")
    func picksSoonestDose() {
        let later = med(id: "later", name: "Later", times: [TimeOfDay(hour: 9, minute: 30)])
        let sooner = med(id: "sooner", name: "Sooner", times: [TimeOfDay(hour: 8, minute: 30)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [later, sooner],
            intakes: [],
            now: now
        )
        #expect(dose?.medicationId == "sooner")
    }

    // MARK: - v0.8.5 WFIX-LA — per-medication Live-Activity gate

    @Test("Does not surface a due dose when its per-med Live-Activity toggle is OFF")
    func skipsDoseWhenLiveActivityDisabled() {
        // Dose at 09:00, in-window — but the per-med toggle is off for it.
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now,
            isLiveActivityEnabled: { _ in false }
        )
        #expect(dose == nil)
    }

    @Test("Surfaces a due dose when its per-med Live-Activity toggle is ON")
    func surfacesDoseWhenLiveActivityEnabled() {
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now,
            isLiveActivityEnabled: { $0 == "med-1" }
        )
        #expect(dose?.medicationId == "med-1")
    }

    @Test("Per-med gate picks the enabled med, skipping a sooner disabled one")
    func gatePicksEnabledOverSoonerDisabled() {
        // Sooner dose (08:30) is disabled; later dose (09:30) is enabled.
        // The gate must skip the sooner-but-disabled med and surface the
        // later-but-enabled one.
        let soonerDisabled = med(id: "sooner", name: "Sooner", times: [TimeOfDay(hour: 8, minute: 30)])
        let laterEnabled = med(id: "later", name: "Later", times: [TimeOfDay(hour: 9, minute: 30)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [soonerDisabled, laterEnabled],
            intakes: [],
            now: now,
            isLiveActivityEnabled: { $0 == "later" }
        )
        #expect(dose?.medicationId == "later")
    }

    @Test("Default (no predicate) surfaces the dose — back-compat")
    func defaultPredicateSurfacesDose() {
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose?.medicationId == "med-1")
    }

    @Test("isResolved matches on medication id + same minute")
    func isResolvedMatchesByMinute() throws {
        let scheduled = try #require(Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: now
        ))
        // Server timestamp drifts by a few seconds — should still match.
        let serverScheduled = scheduled.addingTimeInterval(12)
        let intake = MedicationIntake(
            id: "i1",
            medicationId: "med-1",
            scheduledAt: serverScheduled,
            takenAt: now,
            status: .taken
        )
        #expect(
            MedicationLiveActivityPlan.isResolved(
                medicationId: "med-1",
                scheduledFor: scheduled,
                intakes: [intake]
            )
        )
        // A pending intake is NOT resolved.
        let pending = MedicationIntake(
            id: "i2",
            medicationId: "med-1",
            scheduledAt: scheduled,
            status: .pending
        )
        #expect(
            !MedicationLiveActivityPlan.isResolved(
                medicationId: "med-1",
                scheduledFor: scheduled,
                intakes: [pending]
            )
        )
    }

    @Test("nextOrCurrentFireDate returns nil for an empty schedule")
    func noFireForEmptySchedule() {
        let schedule = MedicationSchedule(times: [])
        #expect(
            MedicationLiveActivityPlan.nextOrCurrentFireDate(
                schedule: schedule,
                now: now
            ) == nil
        )
    }

    @Test("nextOrCurrentFireDate prefers the soonest upcoming dose over a missed one")
    func prefersUpcomingOverMissed() throws {
        // 07:00 (1h overdue) + 09:00 (1h upcoming). The upcoming one wins.
        let schedule = MedicationSchedule(
            times: [TimeOfDay(hour: 7, minute: 0), TimeOfDay(hour: 9, minute: 0)]
        )
        let fire = MedicationLiveActivityPlan.nextOrCurrentFireDate(
            schedule: schedule,
            now: now
        )
        let hour = try Calendar.current.component(.hour, from: #require(fire))
        #expect(hour == 9)
    }

    // MARK: - v0.10 R1 §3.6 — engine-driven surfacing + per-schedule grace

    private func entryMed(
        id: String = "med-roll",
        cadence: Cadence,
        time: TimeOfDay,
        grace: Int? = nil,
        lastTakenAt: Date? = nil,
        startsOn: Date? = nil,
        oneShot: Bool = false
    ) -> Medication {
        let entry = ScheduleEntry(
            cadence: cadence,
            timesOfDay: [time],
            reminderGraceMinutes: grace,
            windowStart: time
        )
        return Medication(
            id: id,
            name: "Test",
            dose: "1",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTakenAt,
            notificationsEnabled: true,
            active: true,
            startsOn: startsOn,
            oneShot: oneShot
        )
    }

    /// 7 days before `now`'s day at 07:00 — the rolling anchor that lands the
    /// next-due slot at 07:00 today.
    private func sevenDaysAgoAt7() throws -> Date {
        let base = try #require(Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: now))
        return try #require(Calendar.current.date(byAdding: .day, value: -7, to: base))
    }

    @Test("Rolling med surfaces its single overdue slot inside the per-schedule grace")
    func rollingSurfacesOverdueWithinGrace() throws {
        // now = 08:00. 7-day rolling med whose next-due lands at 07:00 today
        // → 1h overdue. grace = 120 min → still inside the window → surfaced.
        let medication = try entryMed(
            cadence: .rolling(intervalDays: 7),
            time: TimeOfDay(hour: 7, minute: 0),
            grace: 120,
            lastTakenAt: sevenDaysAgoAt7()
        )
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose?.medicationId == "med-roll")
    }

    @Test("Rolling med past its per-schedule grace is NOT surfaced")
    func rollingNotSurfacedPastGrace() throws {
        // Same setup but grace = 30 min → the 07:00 dose (1h overdue at 08:00)
        // is past its grace window → dropped.
        let medication = try entryMed(
            cadence: .rolling(intervalDays: 7),
            time: TimeOfDay(hour: 7, minute: 0),
            grace: 30,
            lastTakenAt: sevenDaysAgoAt7()
        )
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose == nil)
    }

    @Test("nextOrCurrentOccurrence surfaces a rolling next-due slot")
    func nextOccurrenceRolling() {
        let lastTaken = now.addingTimeInterval(-5 * 86400)
        let medication = entryMed(
            cadence: .rolling(intervalDays: 7),
            time: TimeOfDay(hour: 9, minute: 0),
            lastTakenAt: lastTaken
        )
        let occurrence = MedicationLiveActivityPlan.nextOrCurrentOccurrence(
            medication: medication,
            now: now
        )
        #expect(occurrence != nil)
    }
}

// MARK: - W-B183 — server-gated overdue carried into the ContentState

/// **W-B183 (dose-safety coherence — the Trulicity Live-Activity bug).**
///
/// Pins that the Live-Activity overdue verdict the app carries into the widget
/// (`MedicationLiveActivityPlan.isOverdue` → `DoseActivity.isOverdue`) is the
/// SAME server-gated truth the in-app card uses, NOT the widget's old
/// `Date.now > countdownTarget`.
@Suite("MedicationLiveActivityPlan — W-B183 server-gated overdue")
struct MedicationLiveActivityOverdueTests {
    /// Fixed reference clock: 2026-05-29 08:00 local.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 29
        comps.hour = 8
        comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    /// A rolling/weekly med whose server next-due is strictly in the FUTURE
    /// (taken weekly, next dose weeks away, no open overdue slot) must read
    /// `isOverdue == false` even when the LOCAL window grid has long passed —
    /// i.e. even when `Date.now > countdownTarget`. Before the fix the widget
    /// computed overdue itself as `Date.now > countdownTarget`, bypassing the
    /// server gate, and painted the dose red ("stark überfällig"). The plan now
    /// mirrors the in-app card's `reduce(...) ?? serverOverdueFallback(...)`
    /// composition (which suppresses `.late`/`.veryLate` under a future server
    /// due), so the carried flag is neutral.
    @Test("Future-server-due weekly med reads isOverdue == false despite a past local window")
    func futureServerDueWeeklyIsNotOverdue() throws {
        // Weekly (every-7-days rolling) med, window at 07:00. now = 08:00, so
        // the LOCAL window (07:00–09:00 grace) has its instant in the PAST —
        // `Date.now > countdownTarget` would be TRUE → the old widget went red.
        // But the server says the next dose is 7 days out and flags NO open
        // overdue slot → the card (and now the Live Activity) must stay neutral.
        let serverNextDue = try #require(Calendar.current.date(byAdding: .day, value: 7, to: now))
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 7, minute: 0)],
            reminderGraceMinutes: 120,
            windowStart: TimeOfDay(hour: 7, minute: 0)
        )
        // Taken weekly → 100% compliance; last dose covers the passed slot.
        let lastTaken = try #require(Calendar.current.date(byAdding: .day, value: -7, to: now))
        let medication = Medication(
            id: "trulicity",
            name: "Trulicity",
            dose: "2.5 mg",
            treatmentClass: "GLP1",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTaken,
            todayEventCount: 0,
            notificationsEnabled: true,
            active: true,
            nextDueAt: serverNextDue,
            nextDueOverdue: false
        )

        // Sanity: the local clock IS past the would-be countdown target.
        let pastTarget = try #require(Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: now))
        #expect(now > pastTarget, "precondition: Date.now > local window instant")

        // The server-gated truth the ContentState carries must be neutral.
        #expect(
            MedicationLiveActivityPlan.isOverdue(medication: medication, now: now) == false,
            "A strictly-future server next-due with no open overdue slot must NOT read overdue"
        )
    }

    /// Counterpart: an OPEN overdue slot the server flags (`nextDueOverdue`
    /// with a past `nextDueAt`) DOES read overdue — the server-authoritative
    /// `serverOverdueFallback` path the card also surfaces.
    @Test("Server-flagged open overdue slot reads isOverdue == true")
    func serverOpenOverdueIsOverdue() throws {
        let pastDue = try #require(Calendar.current.date(byAdding: .hour, value: -1, to: now))
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 7),
            timesOfDay: [TimeOfDay(hour: 7, minute: 0)],
            reminderGraceMinutes: 120,
            windowStart: TimeOfDay(hour: 7, minute: 0)
        )
        let medication = Medication(
            id: "trulicity",
            name: "Trulicity",
            dose: "2.5 mg",
            treatmentClass: "GLP1",
            schedule: MedicationSchedule(entries: [entry]),
            notificationsEnabled: true,
            active: true,
            nextDueAt: pastDue,
            nextDueOverdue: true
        )
        #expect(
            MedicationLiveActivityPlan.isOverdue(medication: medication, now: now) == true,
            "An open overdue slot (server-flagged, past instant) must read overdue"
        )
    }

    /// The carried flag rides through `doseToSurface`'s `DoseActivity` so the
    /// reconcile path hands the controller the same server-gated truth. A dose
    /// surfaced INSIDE its lead window but whose window has NOT yet opened
    /// (08:00 now, 08:30 due) is not overdue → the carried flag is `false`.
    @Test("doseToSurface carries isOverdue == false for a not-yet-due in-window dose")
    func doseActivityCarriesNeutralOverdue() {
        // Daily 08:30 dose, now 08:00 → inside the 2h lead window (surfaces) but
        // its window has not opened → nothing overdue → carried flag `false`.
        let medication = Medication(
            id: "med-1",
            name: "Vitamin D",
            dose: "1000 IE",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 30)]),
            notificationsEnabled: true,
            active: true
        )
        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: [medication],
            intakes: [],
            now: now
        )
        #expect(dose?.medicationId == "med-1")
        #expect(dose?.isOverdue == false, "A not-yet-due in-window dose must surface neutral")
    }
}
