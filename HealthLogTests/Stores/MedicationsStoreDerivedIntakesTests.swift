import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.5.5.1 W-MED2 regression coverage.**
///
/// Pins the operator-reported "Lisinopril zweimal/Tag, kann nichts nehmen"
/// blocker on TestFlight build 21. The server's `reminder-worker.ts`
/// only materialises a `MedicationIntakeEvent` row when the schedule
/// window enters the RED phase; before that the
/// `GET /api/medications/intake?scope=today` endpoint returns `[]`
/// and the UI surfaced its empty state for the entire pre-RED window
/// (i.e. the entire window-start → near-window-end span the operator
/// actually needs the affordance for).
///
/// `MedicationsStore.deriveTodayIntakes` merges server-emitted intakes
/// with synthesised placeholders so the UI surfaces a pending row for
/// every schedule slot today, regardless of whether the server has
/// already created the matching event row.
@Suite("MedicationsStore — derived today intakes (W-MED2)")
struct MedicationsStoreDerivedIntakesTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// 2026-05-21 (Thursday) 14:00 Berlin — between Lisinopril's morning
    /// window (07:00) and evening window (19:00). Reproduces the
    /// operator's exact wall-clock when the screenshot was taken.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 21
        components.hour = 14
        components.minute = 0
        components.timeZone = berlin
        return Calendar.berlin.date(from: components)!
    }()

    private static func lisinopril(
        id: String = "med-lisinopril",
        active: Bool = true,
        times: [TimeOfDay] = [TimeOfDay(hour: 7, minute: 0), TimeOfDay(hour: 19, minute: 0)],
        weekdays: Set<Weekday>? = nil,
        intervalWeeks: Int = 1
    ) -> Medication {
        Medication(
            id: id,
            name: "Lisinopril",
            dose: "5mg",
            schedule: MedicationSchedule(
                times: times,
                weekdays: weekdays,
                intervalWeeks: intervalWeeks
            ),
            notificationsEnabled: true,
            active: active
        )
    }

    // MARK: - The bug as reported

    @Test("Operator's Lisinopril 2×/day: server returns [] → derive synthesises two pending placeholders")
    func twiceDailyServerEmptyYieldsTwoPlaceholders() {
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [Self.lisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 2)
        #expect(derived.allSatisfy(\.isSynthesizedPlaceholder) == true)
        #expect(derived.allSatisfy { $0.medicationId == "med-lisinopril" } == true)
        #expect(derived.allSatisfy { $0.status == .pending } == true)
        let hours = derived.map { Calendar.berlin.component(.hour, from: $0.scheduledAt) }
        #expect(hours == [7, 19], "chronological order — morning first, evening second")
    }

    @Test("Synthetic intake ids carry the synth: prefix so the UI can route mark-as-taken via the bulk-intake endpoint")
    func placeholderIdShapeIsStableAndDetectable() {
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [Self.lisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        for intake in derived {
            #expect(intake.id.hasPrefix(MedicationIntake.synthesizedPlaceholderPrefix))
            #expect(intake.id.contains("med-lisinopril"))
            #expect(intake.isSynthesizedPlaceholder)
        }
    }

    // MARK: - De-duplication contract

    @Test("Server-emitted row suppresses the matching synthesised placeholder (±5 min window)")
    func serverIntakeSuppressesPlaceholder() throws {
        // Server has already materialised the 07:00 slot (in RED-phase).
        let morningServerSlot = try #require(Calendar.berlin.date(bySettingHour: 7, minute: 1, second: 0, of: Self.now))
        let serverIntake = MedicationIntake(
            id: "server-intake-1",
            medicationId: "med-lisinopril",
            scheduledAt: morningServerSlot,
            takenAt: nil,
            status: .pending,
            snoozedUntil: nil
        )

        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [serverIntake],
            medications: [Self.lisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 2)
        // The 07:00 slot is the server row (not synthesised).
        let morning = derived[0]
        #expect(morning.id == "server-intake-1")
        #expect(!morning.isSynthesizedPlaceholder)
        // The 19:00 slot remains a synthesised placeholder.
        let evening = derived[1]
        #expect(evening.isSynthesizedPlaceholder)
    }

    @Test("Server rows outside the ±5 min dedup window do not suppress the placeholder (mismatched schedule)")
    func serverIntakeOutsideDedupWindowDoesNotSuppress() throws {
        // Server has a row at 06:00 — outside the ±5 min window of the
        // 07:00 schedule slot. Both surface.
        let earlyMorning = try #require(Calendar.berlin.date(bySettingHour: 6, minute: 0, second: 0, of: Self.now))
        let serverIntake = MedicationIntake(
            id: "server-other",
            medicationId: "med-lisinopril",
            scheduledAt: earlyMorning,
            takenAt: nil,
            status: .pending,
            snoozedUntil: nil
        )

        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [serverIntake],
            medications: [Self.lisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 3)
        #expect(derived.contains(where: { $0.id == "server-other" }))
        #expect(derived.filter(\.isSynthesizedPlaceholder).count == 2)
    }

    // MARK: - Active-medication gate

    @Test("Archived medications (active=false) do not produce placeholders")
    func archivedMedicationProducesNoPlaceholders() {
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [Self.lisinopril(active: false)],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty)
    }

    // MARK: - Weekday filter

    @Test("Schedule restricted to weekdays excluding today produces no placeholder")
    func weekdayConstraintExcludesToday() {
        // 2026-05-21 is a Thursday. Restrict the schedule to Mon-Fri minus Thursday.
        let weekdays: Set<Weekday> = [.mon, .tue, .wed, .fri]
        let med = Self.lisinopril(weekdays: weekdays)
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty)
    }

    @Test("Schedule restricted to weekdays including today produces placeholders")
    func weekdayConstraintIncludingTodayPasses() {
        let med = Self.lisinopril(weekdays: [.thu])
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 2)
    }

    // MARK: - No-schedule defensive

    @Test("Medication without schedule times produces no placeholder (PRN)")
    func emptyScheduleProducesNoPlaceholder() {
        let med = Self.lisinopril(times: [])
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty)
    }

    // MARK: - Stable ordering

    @Test("Mixed server + synthetic rows sort by scheduledAt ascending (server-first on ties)")
    func mergedOrderingIsChronological() throws {
        let earlyMorningServer = try #require(Calendar.berlin.date(bySettingHour: 6, minute: 0, second: 0, of: Self.now))
        let lateEveningServer = try #require(Calendar.berlin.date(bySettingHour: 22, minute: 0, second: 0, of: Self.now))
        let server = [
            MedicationIntake(
                id: "server-late",
                medicationId: "med-lisinopril",
                scheduledAt: lateEveningServer,
                takenAt: nil,
                status: .pending
            ),
            MedicationIntake(
                id: "server-early",
                medicationId: "med-lisinopril",
                scheduledAt: earlyMorningServer,
                takenAt: nil,
                status: .pending
            )
        ]
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: server,
            medications: [Self.lisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        // Expect: 06:00 (server-early), 07:00 (synth), 19:00 (synth), 22:00 (server-late).
        #expect(derived.count == 4)
        #expect(derived[0].id == "server-early")
        #expect(derived[1].isSynthesizedPlaceholder)
        #expect(derived[2].isSynthesizedPlaceholder)
        #expect(derived[3].id == "server-late")
    }

    // MARK: - v0.10 R1 §3.3 — cadence-aware synthesis (the "fires daily" fix)

    private static func entryMed(
        id: String,
        cadence: Cadence,
        time: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
        lastTakenAt: Date? = nil,
        startsOn: Date? = nil,
        oneShot: Bool = false
    ) -> Medication {
        let entry = ScheduleEntry(
            cadence: cadence,
            timesOfDay: [time],
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

    @Test("Rolling med synthesises exactly ONE slot, not one per day")
    func rollingFiresOnceNotDaily() throws {
        // 30-day rolling, last taken 25 days ago → next-due is 5 days away
        // (in the future), so it should NOT surface as a today-placeholder.
        let lastTaken = try #require(Calendar.berlin.date(byAdding: .day, value: -25, to: Self.now))
        let med = Self.entryMed(id: "med-roll", cadence: .rolling(intervalDays: 30), lastTakenAt: lastTaken)
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty, "future rolling slot is not a today-placeholder")
    }

    @Test("Rolling med overdue → surfaces the single overdue slot today")
    func rollingOverdueSurfacesOnce() throws {
        // 30-day rolling, last taken 40 days ago → next-due was 10 days ago
        // (overdue) → exactly one placeholder, not 40.
        let lastTaken = try #require(Calendar.berlin.date(byAdding: .day, value: -40, to: Self.now))
        let med = Self.entryMed(id: "med-roll", cadence: .rolling(intervalDays: 30), lastTakenAt: lastTaken)
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 1)
        #expect(derived.allSatisfy(\.isSynthesizedPlaceholder) == true)
    }

    // MARK: - W10 M4 — placeholder uses serverNextDueAt so it agrees with the reminder

    @Test("Rolling med: today-placeholder uses serverNextDueAt, matching the reminder slot")
    func rollingPlaceholderPrefersServerNextDueAt() throws {
        // lastTakenAt 40 days ago → local projection's next-due is 10 days ago
        // (overdue). The server re-anchored nextDueAt to TODAY at 09:00. The
        // reminder (engine.nextOccurrence) already prefers serverNextDueAt; M4
        // makes the in-app placeholder agree instead of using the divergent
        // local 10-days-ago instant.
        let lastTaken = try #require(Calendar.berlin.date(byAdding: .day, value: -40, to: Self.now))
        let serverNextDue = try #require(
            Calendar.berlin.date(
                bySettingHour: 9, minute: 0, second: 0, of: Self.now
            )
        )
        let entry = ScheduleEntry(
            cadence: .rolling(intervalDays: 30),
            timesOfDay: [TimeOfDay(hour: 9, minute: 0)],
            windowStart: TimeOfDay(hour: 9, minute: 0)
        )
        let med = Medication(
            id: "med-roll-server",
            name: "Test",
            dose: "1",
            schedule: MedicationSchedule(entries: [entry]),
            lastTakenAt: lastTaken,
            notificationsEnabled: true,
            active: true,
            nextDueAt: serverNextDue
        )
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 1)
        let placeholder = try #require(derived.first)
        #expect(placeholder.isSynthesizedPlaceholder)
        // The placeholder must sit at the server instant, NOT the local
        // 10-days-ago projection.
        #expect(abs(placeholder.scheduledAt.timeIntervalSince(serverNextDue)) < 1)
    }

    @Test("Rolling med without serverNextDueAt falls back to the local projection")
    func rollingPlaceholderFallsBackLocalWithoutServer() throws {
        // No nextDueAt → the local engine projection drives the placeholder
        // (overdue slot surfaces today). Pins the fallback (no regression).
        let lastTaken = try #require(Calendar.berlin.date(byAdding: .day, value: -40, to: Self.now))
        let med = Self.entryMed(
            id: "med-roll-local",
            cadence: .rolling(intervalDays: 30),
            lastTakenAt: lastTaken
        )
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 1)
    }

    @Test("Monthly med does NOT fire on a non-matching day")
    func monthlyNoFireOffDay() {
        // Today is 2026-05-21; a monthly-on-1st med must produce nothing.
        let med = Self.entryMed(id: "med-month", cadence: .monthly(day: 1))
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty)
    }

    @Test("Monthly med fires on its matching day")
    func monthlyFiresOnMatchingDay() {
        // Today is 2026-05-21; a monthly-on-21st med must produce one slot.
        let med = Self.entryMed(id: "med-month", cadence: .monthly(day: 21))
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 1)
    }

    @Test("Yearly med does NOT fire daily")
    func yearlyNoFireOffDay() {
        let med = Self.entryMed(id: "med-year", cadence: .yearly(month: 1, day: 1))
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.isEmpty)
    }

    @Test("One-shot med surfaces once on its startsOn day, then stops after take")
    func oneShotStopsAfterTake() {
        let startsOn = Calendar.berlin.startOfDay(for: Self.now)
        let med = Self.entryMed(
            id: "med-shot",
            cadence: .oneShot,
            time: TimeOfDay(hour: 10, minute: 0),
            startsOn: startsOn,
            oneShot: true
        )
        // Before any intake: one placeholder on the startsOn day.
        let before = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [med],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(before.count == 1)

        // After the server marks it taken + deactivates (active=false), the
        // medication drops out of synthesis entirely.
        let takenMed = Medication(
            id: med.id,
            name: med.name,
            dose: med.dose,
            schedule: med.schedule,
            lastTakenAt: Self.now,
            notificationsEnabled: true,
            active: false,
            startsOn: startsOn,
            oneShot: true
        )
        let after = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [takenMed],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(after.isEmpty)
    }
}

private extension Calendar {
    /// Berlin-anchored calendar so the W-MED2 tests are timezone-stable
    /// regardless of CI runner locale.
    static var berlin: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.locale = Locale(identifier: "de_DE")
        return cal
    }
}

/// **B2 (v0.10.0 Walkthrough-1) — dose-instant dedup across duplicate entries.**
///
/// A twice-daily Lisinopril modelled as TWO schedule entries that EACH carry both
/// times (08:00 + 20:00) made the synthesis loop `for entry × effectiveTimes` →
/// 2×2 = 4 placeholders, inflating the dashboard compliance-ring denominator to
/// "x/4". The dedup collapses duplicate whole-minute clock-times so the med
/// yields exactly 2 distinct dose slots.
@Suite("MedicationsStore — dose-instant dedup (B2)")
struct MedicationsStoreDoseDedupTests {
    /// 2026-05-21 (Thursday) 14:00 Berlin — same wall-clock as the W-MED2 suite.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 21
        components.hour = 14
        components.minute = 0
        components.timeZone = TimeZone(identifier: "Europe/Berlin")
        return Calendar.berlin.date(from: components)!
    }()

    private static func doubledLisinopril() -> Medication {
        let times = [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)]
        let entry = ScheduleEntry(cadence: .daily, timesOfDay: times, windowStart: times[0])
        // Two identical entries — the over-count shape from the diagnosis.
        return Medication(
            id: "med-lisinopril",
            name: "Lisinopril",
            dose: "5mg",
            schedule: MedicationSchedule(entries: [entry, entry]),
            notificationsEnabled: true,
            active: true
        )
    }

    @Test("Two entries carrying the same two times collapse to 2 distinct dose slots, not 4")
    func duplicateEntriesDedupToDistinctDoses() {
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: [],
            medications: [Self.doubledLisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        #expect(derived.count == 2, "two entries × two times must collapse to 2 distinct dose slots")
        let hours = derived.map { Calendar.berlin.component(.hour, from: $0.scheduledAt) }.sorted()
        #expect(hours == [8, 20])
    }

    @Test("Both doses server-emitted + taken → ring is complete (2/2), no surviving duplicates")
    func bothDosesServerEmittedYieldNoDuplicates() throws {
        let morning = try #require(Calendar.berlin.date(bySettingHour: 8, minute: 0, second: 0, of: Self.now))
        let evening = try #require(Calendar.berlin.date(bySettingHour: 20, minute: 0, second: 0, of: Self.now))
        let server = [
            MedicationIntake(
                id: "srv-am", medicationId: "med-lisinopril", scheduledAt: morning,
                takenAt: morning, status: .taken
            ),
            MedicationIntake(
                id: "srv-pm", medicationId: "med-lisinopril", scheduledAt: evening,
                takenAt: evening, status: .taken
            )
        ]
        let derived = MedicationsStore.deriveTodayIntakes(
            serverIntakes: server,
            medications: [Self.doubledLisinopril()],
            now: Self.now,
            calendar: Calendar.berlin
        )
        // Exactly the two server rows; no synthesised duplicates survive.
        #expect(derived.count == 2)
        #expect(derived.allSatisfy { !$0.isSynthesizedPlaceholder })
        #expect(derived.allSatisfy { $0.status == .taken })
    }
}

// swiftlint:enable force_unwrapping
