import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable type_body_length

/// **v0.6.1.2 Y4 — MedicationDetailStore compliance + verlauf tests.**
///
/// `complianceSummary()` and `verlaufGlyphs()` are the per-detail-
/// screen analogues of `MedicationsStore.complianceSnapshot`. Both
/// derive purely from `intakes`; this suite asserts the in-time
/// counting + glyph bucketing semantics.
@MainActor
@Suite("MedicationDetailStore — compliance + Verlauf")
struct MedicationDetailStoreComplianceTests {
    @Test("All doses taken within ±30 min → 100% in-time")
    func allInTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(intakes: makeWindow(days: 10, deltaSeconds: 0, now: now))
        let summary = store.complianceSummary(now: now)
        #expect(summary.percentage == 100)
        #expect(summary.inTime == summary.total)
    }

    @Test("Half taken on schedule + half taken 2h late → ~50%")
    func halfLateHalfOnTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var intakes = makeWindow(days: 10, deltaSeconds: 0, now: now)
        // Half of them shift to +2h (4×60×60).
        intakes = intakes.enumerated().map { idx, event -> PaginatedIntakeEvent in
            guard idx.isMultiple(of: 2) else { return event }
            return PaginatedIntakeEvent(
                id: event.id,
                takenAt: event.takenAt.flatMap { $0.addingTimeInterval(2 * 60 * 60) },
                skipped: event.skipped,
                scheduledFor: event.scheduledFor,
                injectionSite: event.injectionSite
            )
        }
        let store = makeStore(intakes: intakes)
        let summary = store.complianceSummary(now: now)
        // 5/10 in-time → 50%.
        #expect(summary.percentage == 50)
    }

    @Test("Skipped doses are excluded from the in-time numerator")
    func skippedExcluded() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let intakes = (0 ..< 5).map { offset -> PaginatedIntakeEvent in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return PaginatedIntakeEvent(
                id: "i-\(offset)",
                takenAt: nil,
                skipped: true,
                scheduledFor: scheduled,
                injectionSite: nil
            )
        }
        let store = makeStore(intakes: intakes)
        let summary = store.complianceSummary(now: now)
        // 0 in-time / 5 total → 0%.
        #expect(summary.inTime == 0)
        #expect(summary.total == 5)
        #expect(summary.percentage == 0)
    }

    @Test("Empty intake list → 100% ratio (no past-due to fail)")
    func emptyIntakes() {
        let store = makeStore(intakes: [])
        let summary = store.complianceSummary()
        #expect(summary.total == 0)
        #expect(summary.percentage == 100)
    }

    @Test("Verlauf produces 14 glyphs, oldest first")
    func verlaufLength() {
        let store = makeStore(intakes: [])
        let glyphs = store.verlaufGlyphs()
        #expect(glyphs.count == 14)
    }

    @Test("Verlauf — day with on-time taken intake renders onTime")
    func verlaufOnTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let twoDaysAgoNoon = calendar.startOfDay(
            for: now.addingTimeInterval(-2 * 24 * 60 * 60)
        ).addingTimeInterval(12 * 60 * 60)
        let event = PaginatedIntakeEvent(
            id: "i-1",
            takenAt: twoDaysAgoNoon,
            skipped: false,
            scheduledFor: twoDaysAgoNoon,
            injectionSite: nil
        )
        let store = makeStore(intakes: [event])
        let glyphs = store.verlaufGlyphs(now: now)
        // Index 11 = 2 days ago (oldest-first ordering, 14 days back ... today).
        #expect(glyphs[11] == .onTime)
    }

    @Test("Verlauf — day with missed past-due intake renders missed")
    func verlaufMissed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let threeDaysAgoNoon = calendar.startOfDay(
            for: now.addingTimeInterval(-3 * 24 * 60 * 60)
        ).addingTimeInterval(12 * 60 * 60)
        let event = PaginatedIntakeEvent(
            id: "i-1",
            takenAt: nil,
            skipped: false,
            scheduledFor: threeDaysAgoNoon,
            injectionSite: nil
        )
        let store = makeStore(intakes: [event])
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[10] == .missed)
    }

    @Test("Verlauf — day with no scheduled intake renders noSchedule")
    func verlaufNoSchedule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(intakes: [])
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[0] == .noSchedule)
    }

    // MARK: - v0.6.2.3 B1 — server-canonical payload consumption

    @Test("Server compliance30 payload drives the KPI summary")
    func serverPayloadDrivesKPI() {
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1,
                taken: 1,
                skipped: 0,
                missed: 0,
                rate: 100,
                streak: 1
            ),
            // Weekly Lisinopril 4-week window — totalExpected = 4 slots,
            // 3 taken, 1 missed. With the old client-derived view the
            // KPI read "0 von 2" because the paged-intake set only
            // exposed two slots. The server numbers are authoritative.
            compliance30: ComplianceWindowResult(
                totalExpected: 4,
                taken: 3,
                skipped: 0,
                missed: 1,
                rate: 75,
                streak: 0
            ),
            dailyCompliance: [:]
        )
        let store = makeStore(intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        #expect(summary.inTime == 3)
        #expect(summary.total == 4)
        #expect(summary.percentage == 75)
    }

    @Test("Server payload — skipped doses drop out of the denominator")
    func serverPayloadSkippedExcluded() {
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            // 5 expected, 1 skipped, 4 taken → KPI should read "4 von 4".
            compliance30: ComplianceWindowResult(
                totalExpected: 5, taken: 4, skipped: 1, missed: 0, rate: 80, streak: 0
            ),
            dailyCompliance: [:]
        )
        let store = makeStore(intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        #expect(summary.inTime == 4)
        #expect(summary.total == 4)
        #expect(summary.percentage == 100)
    }

    @Test("W45 — Verlauf glyphs are derived from loaded intakes (table parity)")
    func verlaufFromLoadedIntakes() throws {
        // W45 doctrine: the glyph track mirrors the same `intakes` the intake
        // TABLE renders. A taken-on-time day reads `.onTime`, a past-due day
        // with an unactioned slot reads `.missed`, a late day reads `.late`.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func noon(_ daysAgo: Int) throws -> Date {
            let day = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: today))
            return day.addingTimeInterval(12 * 60 * 60)
        }
        let twoNoon = try noon(2)
        let threeNoon = try noon(3)
        let fourNoon = try noon(4)
        let intakes: [PaginatedIntakeEvent] = [
            // Two days ago: taken on-time → .onTime.
            PaginatedIntakeEvent(
                id: "a",
                takenAt: twoNoon,
                skipped: false,
                scheduledFor: twoNoon,
                injectionSite: nil
            ),
            // Three days ago: past-due, never taken → .missed.
            PaginatedIntakeEvent(
                id: "b",
                takenAt: nil,
                skipped: false,
                scheduledFor: threeNoon,
                injectionSite: nil
            ),
            // Four days ago: taken 2h late → .late.
            PaginatedIntakeEvent(
                id: "c",
                takenAt: fourNoon.addingTimeInterval(2 * 60 * 60),
                skipped: false,
                scheduledFor: fourNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes)
        let glyphs = store.verlaufGlyphs(now: now)
        // Oldest-first, 14 entries → today is glyphs[13].
        #expect(glyphs[11] == .onTime)
        #expect(glyphs[10] == .missed)
        #expect(glyphs[9] == .late)
        // A day with no loaded intake reads `.noSchedule` (no row in the table
        // either) — the track only paints from slots that actually exist.
        #expect(glyphs[0] == .noSchedule)
    }

    @Test("W45 — server due=false suppresses an empty (no-intake) day to noSchedule")
    func verlaufServerDueFalseSuppressesEmptyDay() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let oneDayAgo = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 0, taken: 0, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            dailyCompliance: [
                formatter.string(from: oneDayAgo): DailyComplianceBucket(
                    expected: 0, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: false, expectedCount: 0
                )
            ]
        )
        #expect(payload.isV170Capable)
        // No intakes loaded for that day → the v1.7.0 `due == false` overlay
        // suppresses the otherwise-daily med's day to `.noSchedule`.
        let store = makeStore(intakes: [], compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[12] == .noSchedule)
    }

    // MARK: - v0.6.2.8 — weekly cadence guard against server totalExpected bug

    @Test("Weekly med — server inflated totalExpected gets corrected to schedule cadence")
    func weeklyServerExpectedOverride() {
        // Server `calculateCompliance` computes `totalExpected = schedules.length
        // * effectiveDays` (= 30 for a single Wednesday slot over 30 days),
        // ignoring `daysOfWeek`. Trulicity: 4 weekly doses, all taken on
        // time → server returns taken=4, totalExpected=30, rate=13. The
        // KPI must read 4 of 4 (100 %) not 4 of 30 (13 %).
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 7, taken: 1, skipped: 0, missed: 6, rate: 14, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 30, taken: 4, skipped: 0, missed: 26, rate: 13, streak: 0
            ),
            dailyCompliance: [:]
        )
        let weekly = Medication(
            id: "med-trulicity",
            name: "Trulicity",
            dose: "7.5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0)],
                weekdays: [.wed],
                intervalWeeks: 1
            )
        )
        let store = makeStore(medication: weekly, intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        // 4-5 Wednesdays land inside any 30-day window. The KPI must
        // read against that, not the inflated 30.
        #expect(summary.total <= 5)
        #expect(summary.total >= 4)
        #expect(summary.inTime == 4)
        #expect(summary.percentage >= 80)
    }

    // MARK: - v0.10 W-Meds-A2 — v1.7.0 SB-SCHED-2 capability gate

    @Test("v1.7.0-capable payload trusts server totalExpected (no local cap)")
    func v170CapableTrustsServerExpected() {
        // Same weekly Trulicity as the pre-v1.7.0 guard, but now the server is
        // cadence-canonical: it emits `due`/`expectedCount` per day AND the
        // window `totalExpected` is already correct (4, not 30). The gate must
        // drop the local cap and read the server's 4 verbatim.
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 4, taken: 4, skipped: 0, missed: 0, rate: 100, streak: 4
            ),
            // Presence of `due`/`expectedCount` on ANY bucket flips capability.
            dailyCompliance: [
                "2026-05-13": DailyComplianceBucket(
                    expected: 1, taken: 1, skipped: 0, onTime: 1, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        #expect(payload.isV170Capable)
        let weekly = Medication(
            id: "med-trulicity",
            name: "Trulicity",
            dose: "7.5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0)],
                weekdays: [.wed],
                intervalWeeks: 1
            )
        )
        let store = makeStore(medication: weekly, intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        // Server is trusted verbatim: 4 expected, 4 taken, 100 %.
        #expect(summary.total == 4)
        #expect(summary.inTime == 4)
        #expect(summary.percentage == 100)
    }

    @Test("Current server (no due/expectedCount) keeps the pre-v1.7.0 cap")
    func currentServerKeepsLocalCap() {
        // Buckets WITHOUT `due`/`expectedCount` → not capable → the old
        // engine-cap path runs unchanged (this pins the no-flip guarantee).
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 7, taken: 1, skipped: 0, missed: 6, rate: 14, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 30, taken: 4, skipped: 0, missed: 26, rate: 13, streak: 0
            ),
            dailyCompliance: [:]
        )
        #expect(!payload.isV170Capable)
        let weekly = Medication(
            id: "med-trulicity",
            name: "Trulicity",
            dose: "7.5 mg",
            schedule: MedicationSchedule(
                times: [TimeOfDay(hour: 8, minute: 0)],
                weekdays: [.wed],
                intervalWeeks: 1
            )
        )
        let store = makeStore(medication: weekly, intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        // Local cap still corrects the inflated 30 → ≤ 5 Wednesdays.
        #expect(summary.total <= 5)
        #expect(summary.inTime == 4)
    }

    @Test("W45 — server due=false suppresses an off-day even when the local schedule fires daily")
    func v170VerlaufSuppressesNonDue() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let twoNoon = twoDaysAgo.addingTimeInterval(12 * 60 * 60)
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            dailyCompliance: [
                // NOT due (off-week) but the server still emitted a bucket — the
                // overlay must suppress an EMPTY (no-intake) day to .noSchedule,
                // NOT paint .missed, even though the local daily schedule fires.
                formatter.string(from: threeDaysAgo): DailyComplianceBucket(
                    expected: 0, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: false, expectedCount: 0
                )
            ]
        )
        #expect(payload.isV170Capable)
        // Two days ago carries a real loaded intake → renders from it (.onTime),
        // proving the table's truth wins on days that HAVE intakes.
        let intakes = [
            PaginatedIntakeEvent(
                id: "a",
                takenAt: twoNoon,
                skipped: false,
                scheduledFor: twoNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes, compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now)
        #expect(glyphs[11] == .onTime) // two days ago (loaded intake wins)
        #expect(glyphs[10] == .noSchedule) // three days ago (empty + due=false → suppressed)
    }

    // MARK: - B15 — user-tz day-key (Berlin) must resolve, not dash

    @Test("B15 — Berlin user: taken day resolves to .onTime, not a UTC-off-by-one dash")
    func berlinDayKeyResolves() throws {
        // Repro of the v0.10.0 B15 dashes bug. The server (v1.7.0) keys
        // `dailyCompliance` by `userDayKey(dayStart, "Europe/Berlin")` — the
        // user-tz local day. Before the fix iOS read it back with a hard-coded
        // UTC formatter over `Calendar.current` local-midnight day starts, so
        // for a Berlin user (UTC+2 in May) the local midnight formatted in UTC
        // resolved to the PREVIOUS calendar day → every bucket lookup missed →
        // `.noSchedule` everywhere. With the fix the formatter tracks the
        // caller's calendar timezone, so the iOS key == the server key.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin

        // 2026-05-30 08:00 Berlin (a morning — well past local midnight).
        var comps = DateComponents()
        comps.timeZone = berlin
        comps.year = 2026
        comps.month = 5
        comps.day = 30
        comps.hour = 8
        comps.minute = 0
        let now = try #require(calendar.date(from: comps))

        // Server bucket keyed exactly as `userDayKey(dayStart, "Europe/Berlin")`
        // would: the Berlin-local calendar day → "2026-05-30".
        let serverKeyFormatter = DateFormatter()
        serverKeyFormatter.calendar = Calendar(identifier: .gregorian)
        serverKeyFormatter.locale = Locale(identifier: "en_US_POSIX")
        serverKeyFormatter.timeZone = berlin
        serverKeyFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = serverKeyFormatter.string(from: now)
        #expect(todayKey == "2026-05-30")

        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 1, taken: 1, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            dailyCompliance: [
                todayKey: DailyComplianceBucket(
                    expected: 1, taken: 1, skipped: 0, onTime: 1, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        #expect(payload.isV170Capable)

        // W45 — the glyph comes from the loaded intake (the table's truth), not
        // the server bucket. A taken-today intake renders `.onTime`; the Berlin
        // tz still matters because the day-bucketing of the intake must land on
        // the same local day the track iterates.
        let todayNoon = try #require(calendar.date(from: {
            var c = comps
            c.hour = 12
            return c
        }()))
        let intakes = [
            PaginatedIntakeEvent(
                id: "a",
                takenAt: todayNoon,
                skipped: false,
                scheduledFor: todayNoon,
                injectionSite: nil
            )
        ]
        let store = makeStore(intakes: intakes, compliance: payload)
        let glyphs = store.verlaufGlyphs(now: now, calendar: calendar)
        // Last glyph = today (2026-05-30 Berlin). The taken intake → .onTime.
        #expect(glyphs.last == .onTime)
    }

    // MARK: - W10 M5 — engine-0 must not fall back to the inflated server grid

    @Test("Engine-0 expected (PRN) is trusted, not replaced by the inflated server total")
    func engineZeroExpectedTrusted() {
        // A PRN / as-needed med projects 0 expected doses over any window. The
        // pre-v1.7.0 server still reports `totalExpected = schedules.length *
        // days` (here 30). The OLD code discarded the correct local 0 and
        // trusted the 30 → a pessimistic denominator. M5 trusts the engine 0:
        // not-due window → 0 expected → 100 %.
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 7, taken: 0, skipped: 0, missed: 7, rate: 0, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 30, taken: 0, skipped: 0, missed: 30, rate: 0, streak: 0
            ),
            dailyCompliance: [:] // pre-v1.7.0: no due/expectedCount → not capable
        )
        #expect(!payload.isV170Capable)
        let prn = Medication(
            id: "med-prn",
            name: "Naproxen",
            dose: "400 mg",
            schedule: MedicationSchedule(entries: [
                ScheduleEntry(
                    cadence: .asNeeded,
                    timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                    windowStart: TimeOfDay(hour: 8, minute: 0)
                )
            ])
        )
        let store = makeStore(medication: prn, intakes: [], compliance: payload)
        let summary = store.complianceSummary()
        // Engine yields 0 expected → denominator 0 → 100 %, NOT 0/30 = 0 %.
        #expect(summary.total == 0)
        #expect(summary.percentage == 100)
    }

    @Test("Future startsOn — engine-0 trusted over the inflated server grid")
    func futureStartsOnEngineZeroTrusted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // startsOn 60 days in the future → no occurrence in the trailing 30-day
        // window → engine projects 0. Server grid still inflates to 30.
        let future = now.addingTimeInterval(60 * 24 * 60 * 60)
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 7, taken: 0, skipped: 0, missed: 7, rate: 0, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 30, taken: 0, skipped: 0, missed: 30, rate: 0, streak: 0
            ),
            dailyCompliance: [:]
        )
        let med = Medication(
            id: "med-future",
            name: "Daily future",
            dose: "1",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)]),
            startsOn: future
        )
        let store = makeStore(medication: med, intakes: [], compliance: payload)
        let summary = store.complianceSummary(now: now)
        #expect(summary.total == 0)
        #expect(summary.percentage == 100)
    }

    // MARK: - W42 — degenerate server window must not clobber the loaded history

    @Test("Server window smaller than the loaded past-due history does NOT collapse the KPI")
    func degenerateServerWindowDoesNotClobberHistory() {
        // Symptom B repro. A twice-daily Lisinopril with a long history: the
        // store has drained the FULL intake stream, so 53 past-due slots sit in
        // the trailing 30-day window, 33 of them taken in-time. The pre-v1.7.0
        // server, however, returns a degenerate window (totalExpected = 5,
        // taken = 5) because its effective-days clamp only covers the few days
        // the account has existed server-side. The engine-capped path collapsed
        // to min(scheduleExpected, 5) → "5 von 5 / 100 %", clobbering the
        // truthful local read. The KPI must stay on the truthful history.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twiceDaily = Medication(
            id: "med-lisinopril",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [
                TimeOfDay(hour: 8, minute: 0),
                TimeOfDay(hour: 20, minute: 0)
            ])
        )
        // 53 past-due slots in the trailing 30 days, 33 taken in-time, 20 missed.
        var intakes: [PaginatedIntakeEvent] = []
        for i in 0 ..< 53 {
            // Spread the slots across the last 30 days (two per day, ~26 days).
            let scheduled = now.addingTimeInterval(-Double(i) * 12 * 60 * 60)
            let takenInTime = i < 33
            intakes.append(PaginatedIntakeEvent(
                id: "i-\(i)",
                takenAt: takenInTime ? scheduled : nil,
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            ))
        }
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 2, taken: 2, skipped: 0, missed: 0, rate: 100, streak: 1
            ),
            // Degenerate server window: tiny totalExpected/taken.
            compliance30: ComplianceWindowResult(
                totalExpected: 5, taken: 5, skipped: 0, missed: 0, rate: 100, streak: 0
            ),
            dailyCompliance: [:] // pre-v1.7.0: not capable
        )
        #expect(!payload.isV170Capable)
        let store = makeStore(medication: twiceDaily, intakes: intakes, compliance: payload)
        let summary = store.complianceSummary(now: now)
        // Must NOT collapse to 5/5 — the loaded history is the truthful read.
        #expect(summary.total >= 53)
        #expect(summary.inTime == 33)
        #expect(summary.percentage < 100)
    }

    @Test("W-MEDVERIFY — v1.7.0-capable server window wins over loaded intakes (verbatim)")
    func capableServerWindowWinsOverLoadedIntakes() {
        // W-MEDVERIFY (v0.14.8) inverts the old W45 ordering for CAPABLE
        // payloads: the server's cadence-canonical, era-aware window is taken
        // verbatim even when the drained intake table covers the window. The
        // demo walkthrough proof: weekly Trulicity — server graded 3 of 4 slots
        // taken (75 %), while the ±30-min client re-derivation over the SAME
        // drained history read "0 von 4 pünktlich" (every take was 55-78 min
        // late) → card said 75 %, detail said 0 %. Server number must paint.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = MedicationCompliancePayload(
            compliance7: ComplianceWindowResult(
                totalExpected: 1, taken: 0, skipped: 0, missed: 1, rate: 0, streak: 0
            ),
            compliance30: ComplianceWindowResult(
                totalExpected: 4, taken: 3, skipped: 0, missed: 1, rate: 75, streak: 5
            ),
            dailyCompliance: [
                "2026-06-07": DailyComplianceBucket(
                    expected: 1, taken: 0, skipped: 0, onTime: 0, late: 0, veryLate: 0,
                    due: true, expectedCount: 1
                )
            ]
        )
        #expect(payload.isV170Capable)
        // Drained weekly history: 4 in-window slots, 3 taken ~70 min late
        // (outside ±30 min → the legacy local read collapsed to 0 von 4),
        // 1 missed.
        var intakes: [PaginatedIntakeEvent] = []
        for i in 0 ..< 4 {
            let scheduled = now.addingTimeInterval(-Double(i * 7 + 1) * 24 * 60 * 60)
            intakes.append(PaginatedIntakeEvent(
                id: "i-\(i)",
                takenAt: i == 0 ? nil : scheduled.addingTimeInterval(70 * 60),
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            ))
        }
        let store = makeStore(intakes: intakes, compliance: payload)
        let summary = store.complianceSummary(now: now)
        // Server verbatim: 3 von 4 → 75 % — NOT the local 0 von 4 / 0 %.
        #expect(summary.inTime == 3)
        #expect(summary.total == 4)
        #expect(summary.percentage == 75)
    }

    // MARK: - Helpers

    private func makeStore(
        medication: Medication? = nil,
        intakes: [PaginatedIntakeEvent],
        compliance: MedicationCompliancePayload? = nil
    ) -> MedicationDetailStore {
        let resolved = medication ?? Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 12, minute: 0)])
        )
        let stub = MedicationDetailComplianceStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: stub, outbox: outbox)
        let store = MedicationDetailStore(medication: resolved, repo: repo)
        store._testInject(intakes: intakes, compliance: compliance)
        return store
    }

    /// Build N day-spaced intake events, each taken `deltaSeconds` from
    /// the scheduled time.
    private func makeWindow(days: Int, deltaSeconds: TimeInterval, now: Date) -> [PaginatedIntakeEvent] {
        (0 ..< days).map { offset in
            let scheduled = now.addingTimeInterval(Double(-offset) * 24 * 60 * 60)
            return PaginatedIntakeEvent(
                id: "i-\(offset)",
                takenAt: scheduled.addingTimeInterval(deltaSeconds),
                skipped: false,
                scheduledFor: scheduled,
                injectionSite: nil
            )
        }
    }
}

private final class MedicationDetailComplianceStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.canceled
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.canceled
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.canceled
    }
}
