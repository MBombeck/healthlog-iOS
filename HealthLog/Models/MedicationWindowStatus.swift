import Foundation

/// **v0.10.0 Walkthrough-1 B11 — current-window dose status.**
///
/// Pure, `Sendable`, display-only port of the web's
/// `src/lib/medications/window-status.ts` `reduceCurrentWindowStatus`.
/// It answers a single question the card needs but neither the recurrence
/// engine nor `serverNextDueAt` answers (both are *strictly forward*
/// projectors by design): **is a dose for the current/just-passed window
/// due-now or overdue, and still uncovered by today's intakes?**
///
/// At 19:10 a 19:00 dose (window `[19:00, 20:00]`) reads `.inWindow`
/// ("Jetzt fällig"); after the window ends it reads `.late` ("Überfällig")
/// up to `lateMinutes` past the end, then `.veryLate` ("Stark überfällig")
/// up to `missedMinutes`, then falls back to `nil` (the next-dose line
/// takes over). `.late`/`.veryLate` are surfaced ONLY while the passed
/// schedules are uncovered (`todayEventCount < passedScheduleCount`), and
/// `.inWindow` is suppressed once the last intake already falls inside the
/// window — exactly mirroring the web reducer's intake-coverage guard.
///
/// This is **display-only**: it does NOT touch
/// `MedicationRecurrenceEngine` / `serverNextDueAt`, which correctly emit
/// the next *future* slot. The overdue state is a separate, parallel
/// computation over the current window + intake state.
///
/// - Note: Thresholds are the web defaults (`lateMinutes = 120`,
///   `missedMinutes = 240`). iOS has no `/api/settings/reminder-thresholds`
///   client yet — making these server-driven is a tracked follow-up
///   (see `.planning/v0100-marathon/WALKTHROUGH-1-B11-fix-report.md`).
public enum MedicationWindowStatus: Equatable, Sendable {
    /// `now ∈ [windowStart, windowEnd]` — "Jetzt fällig".
    case inWindow
    /// `0 < minutesPastEnd ≤ lateMinutes` and uncovered — "Überfällig".
    case late
    /// `lateMinutes < minutesPastEnd ≤ missedMinutes` and uncovered —
    /// "Stark überfällig".
    case veryLate

    /// Web reminder-threshold defaults (`medication-card.tsx:211-212`).
    /// FOLLOW-UP: thread the server's `/api/settings/reminder-thresholds`
    /// once an iOS client exists, instead of these constants.
    public static let defaultLateMinutes = 120
    public static let defaultMissedMinutes = 240
    static let defaultOnTimeHalfWidthMinutes = 60
    static let defaultEarlyGraceMinutes = 60

    struct DoseBand: Equatable, Sendable {
        let timeOfDay: TimeOfDay
        let startMinutes: Int
        let endMinutes: Int
    }

    struct ResolvedStatus: Equatable, Sendable {
        let status: MedicationWindowStatus
        let band: DoseBand
        let allBands: [DoseBand]
    }

    /// Resolve the most-actionable current-window status across a
    /// medication's schedule entries. Mirrors `reduceCurrentWindowStatus`:
    /// priority `inWindow > late > veryLate`, with the same intake-coverage
    /// suppression. Returns `nil` when the medication is inactive, no entry
    /// is in/just-past its window, or every passed schedule is covered.
    ///
    /// - Parameters:
    ///   - medication: source of `schedule.entries`, `active`, `lastTakenAt`,
    ///     `todayEventCount`.
    ///   - now: the instant to evaluate (injectable for tests).
    ///   - timeZone: the wall-clock timezone for the per-minute arithmetic.
    ///     Defaults to `.current` to match the card's existing surfaces
    ///     (`computeNextDose`, compliance). FOLLOW-UP: thread the server
    ///     profile IANA TZ like the recurrence engine's `Context.timeZone`.
    ///   - lateMinutes / missedMinutes: grace thresholds past window end.
    public static func reduce(
        medication: Medication,
        now: Date = .now,
        timeZone: TimeZone = .current,
        lateMinutes: Int = defaultLateMinutes,
        missedMinutes: Int = defaultMissedMinutes
    ) -> MedicationWindowStatus? {
        guard medication.active else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let entries = medication.schedule.entries
        guard !entries.isEmpty else { return nil }

        let passedDoseCount = countPassedSchedules(
            entries: entries,
            now: now,
            calendar: calendar
        )
        let todayEventCount = medication.todayEventCount ?? 0
        let hasUncoveredOverdue = todayEventCount < passedDoseCount

        // W-B179 (v0.14.9) — server-authoritative future-due gate. When the
        // server's next-due instant still lies in the FUTURE (and no open
        // overdue slot is flagged), the local wall-clock arithmetic must
        // never paint the green "Jetzt fällig" before that dose's WINDOW
        // actually opens. This is the b178 operator regression: a med due
        // "Heute, 21:00" read due-NOW at 10:30 because a degenerate window
        // shape (zero-length window / multi-day catch-up grace) pushed the
        // derived window end past midnight and the overnight-wrap arithmetic
        // claimed the whole morning. Late/very-late grading stays local (web
        // parity) — the gate only suppresses `.inWindow`, composed with the
        // b175 `nextDueOverdue` flag via `serverOverdueFallback`. The local
        // per-dose band itself determines whether its window has opened.
        //
        // W-B180 — the b179 gate compared against the SLOT instant
        // (`nextDueAt`) and was therefore too strict: with the dose's window
        // already open (now ≥ window start) but the slot instant not yet
        // reached, the card stayed neutral while the Live-Activity surface
        // (window-start driven) showed the dose as due. The gate now
        // suppresses only while no current-day per-dose band is open; from
        // the resolved band start onwards the local `.inWindow` verdict
        // stands.
        let serverUpcomingDue: Date? = {
            guard !medication.hasOpenOverdueDose,
                  let due = medication.nextDueAt, due > now else { return nil }
            return due
        }()

        var best: MedicationWindowStatus?
        for entry in entries {
            // W-MEDVERIFY (v0.14.8) — gate the per-entry window check on the
            // cadence's weekday set, exactly like `countPassedSchedules`
            // already does. Without this gate the time-of-day arithmetic
            // alone made a Sunday-only weekly med (Trulicity, 08:00–10:00)
            // read ".inWindow" → "Jetzt fällig" EVERY morning of the week,
            // while the server graded the dose `upcoming` (next Sunday).
            // Mirrors the web reducer's `daysOfWeek` filter; daily / rolling
            // / interval cadences keep evaluating every day (unchanged).
            //
            // W-B179 (v0.14.9) — the gate was one-sided: a window whose end
            // wraps past midnight (e.g. Fri 22:00–02:00) is still open in the
            // early hours of the NEXT day, whose weekday is not in the set.
            // The post-midnight tail therefore gates on YESTERDAY's weekday;
            // `windowStatus` picks the matching flag per evaluation branch.
            let entryFiresToday = firesToday(entry, now: now, calendar: calendar)
            let entryFiredYesterday = calendar.date(byAdding: .day, value: -1, to: now)
                .map { firesToday(entry, now: $0, calendar: calendar) } ?? false
            guard entryFiresToday || entryFiredYesterday else { continue }
            guard let resolved = resolvedWindowStatus(
                entry: entry,
                now: now,
                calendar: calendar,
                lateMinutes: lateMinutes,
                missedMinutes: missedMinutes,
                firesToday: entryFiresToday,
                firedYesterday: entryFiredYesterday
            ) else { continue }
            let status = resolved.status

            // W-B179/W-B180 — the server says the next dose is still upcoming
            // AND its window has not opened yet → nothing is due-now,
            // regardless of what the degenerate local window arithmetic
            // derived. The card then renders the neutral "Heute, HH:MM"
            // next-dose line. Once a current-day per-dose band opens, the
            // local `.inWindow` verdict shows green.
            //
            // W-B183 (operator bug) — the b179/b180 gate suppressed ONLY
            // `.inWindow`, leaving `.late`/`.veryLate` to slip through. For a
            // rolling / weekly-stride / interval cadence every entry is
            // evaluated every day (`firesToday == true`), so an every-7-days
            // med (Trulicity: last dose Fri, next dose weeks away, 100%
            // compliance) was painted "Stark überfällig" on the off-days
            // whenever `now` passed the entry's window end. When the server's
            // next due is strictly in the FUTURE with no open overdue slot,
            // NOTHING is due or overdue — the server owns overdue here via
            // `nextDueOverdue` → `serverOverdueFallback`. Suppress all local
            // verdicts: `.inWindow` until that dose's window opens, and
            // `.late`/`.veryLate` outright.
            if let due = serverUpcomingDue {
                guard status == .inWindow,
                      calendar.isDate(due, inSameDayAs: now) else { continue }
            }

            // Don't surface late/veryLate while every overdue schedule is
            // already covered by today's intake events.
            if status != .inWindow, !hasUncoveredOverdue { continue }

            // Don't surface inWindow if the last intake already falls inside
            // this window today (the user already took it).
            if status == .inWindow,
               isLastIntakeInBand(
                   lastTakenAt: medication.lastTakenAt,
                   band: resolved.band,
                   allBands: resolved.allBands,
                   now: now,
                   calendar: calendar
               )
            {
                continue
            }

            if let current = best {
                if priority(status) > priority(current) { best = status }
            } else {
                best = status
            }
        }
        return best
    }

    // MARK: - v1.16.4 server overdue-flag fallback (GH issue #15)

    /// Surfaces the server-authoritative `nextDueOverdue` flag as the SAME
    /// overdue affordance the local reducer emits, for the cadences the local
    /// window arithmetic cannot see (rolling / weekly-stride / monthly meds
    /// whose open catch-up band spans days, not today's window grid).
    ///
    /// Returns `.late` ("Überfällig", `HLColor.statusWarn` pill) when the
    /// server flagged an open overdue slot whose instant has actually passed
    /// — a subtle, consistent signal; never the louder `.veryLate` because
    /// the server does not grade overdue severity. Returns `nil` otherwise
    /// (regular future next-due, inactive med, clock-skewed future instant).
    ///
    /// Callers compose it BEHIND the local reducer
    /// (`reduce(...) ?? serverOverdueFallback(...)`) so today's finer-grained
    /// in-window/late/very-late grading keeps priority. Display-only — like
    /// `reduce` it never feeds the schedulers, and it cannot collide with the
    /// b162 dose-safety rule: the open slot is `<= now` by definition, so it
    /// is takeable, while future doses stay not-pre-markable.
    public static func serverOverdueFallback(
        medication: Medication,
        now: Date = .now
    ) -> MedicationWindowStatus? {
        guard medication.active,
              medication.hasOpenOverdueDose,
              let due = medication.nextDueAt,
              due <= now else { return nil }
        return .late
    }

    // MARK: - Per-entry window status (mirrors `getWindowStatus`)

    static func windowStatus(
        entry: ScheduleEntry,
        now: Date,
        calendar: Calendar,
        lateMinutes: Int,
        missedMinutes: Int,
        firesToday: Bool = true,
        firedYesterday: Bool = true
    ) -> MedicationWindowStatus? {
        resolvedWindowStatus(
            entry: entry,
            now: now,
            calendar: calendar,
            lateMinutes: lateMinutes,
            missedMinutes: missedMinutes,
            firesToday: firesToday,
            firedYesterday: firedYesterday
        )?.status
    }

    static func resolvedWindowStatus(
        entry: ScheduleEntry,
        now: Date,
        calendar: Calendar,
        lateMinutes: Int,
        missedMinutes: Int,
        firesToday: Bool,
        firedYesterday: Bool
    ) -> ResolvedStatus? {
        let nowMins = minutesOfDay(now, calendar: calendar)
        let bands = resolveDoseBands(entry)
        var best: ResolvedStatus?
        for band in bands {
            let inYesterdayTail = nowMins < band.startMinutes && band.endMinutes > 24 * 60
            guard inYesterdayTail ? firedYesterday : firesToday else { continue }
            let adjustedNow = inYesterdayTail ? nowMins + 24 * 60 : nowMins
            let status: MedicationWindowStatus?
            if adjustedNow >= band.startMinutes, adjustedNow <= band.endMinutes {
                status = .inWindow
            } else {
                let minutesPastEnd = adjustedNow - band.endMinutes
                if minutesPastEnd > 0, minutesPastEnd <= lateMinutes {
                    status = .late
                } else if minutesPastEnd > lateMinutes, minutesPastEnd <= missedMinutes {
                    status = .veryLate
                } else {
                    status = nil
                }
            }
            guard let status else { continue }
            let candidate = ResolvedStatus(status: status, band: band, allBands: bands)
            if let current = best {
                if priority(status) > priority(current.status) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    // MARK: - Intake coverage (mirrors `isLastIntakeInCurrentWindow`)

    static func isLastIntakeInCurrentWindow(
        lastTakenAt: Date?,
        entry: ScheduleEntry,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let resolved = resolvedWindowStatus(
            entry: entry,
            now: now,
            calendar: calendar,
            lateMinutes: defaultLateMinutes,
            missedMinutes: defaultMissedMinutes,
            firesToday: true,
            firedYesterday: true
        ) else { return false }
        return isLastIntakeInBand(
            lastTakenAt: lastTakenAt,
            band: resolved.band,
            allBands: resolved.allBands,
            now: now,
            calendar: calendar
        )
    }

    static func isLastIntakeInBand(
        lastTakenAt: Date?,
        band: DoseBand,
        allBands: [DoseBand],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let lastTakenAt,
              calendar.isDate(lastTakenAt, inSameDayAs: now) else { return false }
        let intakeMinutes = minutesOfDay(lastTakenAt, calendar: calendar)
        let adjustedIntake = intakeMinutes < band.startMinutes && band.endMinutes > 24 * 60
            ? intakeMinutes + 24 * 60
            : intakeMinutes
        let previousBandFloor = allBands
            .map(\.endMinutes)
            .filter { $0 <= band.startMinutes }
            .max() ?? 0
        let startWithGrace = max(
            band.startMinutes - defaultEarlyGraceMinutes,
            previousBandFloor,
            0
        )
        return adjustedIntake >= startWithGrace && adjustedIntake <= band.endMinutes
    }

    // MARK: - Passed-schedule count (mirrors `countPassedSchedules`)

    static func countPassedSchedules(
        entries: [ScheduleEntry],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let nowMins = minutesOfDay(now, calendar: calendar)
        return entries.reduce(into: 0) { total, entry in
            guard firesToday(entry, now: now, calendar: calendar) else { return }
            total += resolveDoseBands(entry).filter { band in
                let sameDayEnd = band.endMinutes > 24 * 60
                    ? band.endMinutes - 24 * 60
                    : band.endMinutes
                return nowMins > sameDayEnd
            }.count
        }
    }

    static func resolveDoseBands(_ entry: ScheduleEntry) -> [DoseBand] {
        if !entry.timesOfDay.isEmpty {
            return entry.timesOfDay.map { time in
                let key = String(format: "%02d:%02d", time.hour, time.minute)
                if let explicit = entry.doseWindows?.first(where: { $0.timeOfDay == key }),
                   let start = TimeOfDay.parse(explicit.start),
                   let end = TimeOfDay.parse(explicit.end)
                {
                    // 09-15 — an explicit band whose end precedes its start
                    // runs past midnight (23:00–02:00), exactly like the
                    // legacy `windowStart`/`windowEnd` pair below, which has
                    // always carried such an end into the next day. The
                    // `inYesterdayTail` arithmetic in `resolvedWindowStatus`
                    // then evaluates it on the following calendar day, gated
                    // on YESTERDAY's weekday — the same path the Friday
                    // 22:00–02:00 case already takes.
                    //
                    // This branch used to require `minutes(start) <=
                    // minutes(end)` and, when that failed, fall through
                    // SILENTLY to the ±60 anchor default below. A declared
                    // 23:00–02:00 window was therefore graded as 22:00–23:59:
                    // the card showed nothing at 00:35 while the declared
                    // window had 85 minutes left, and painted "Jetzt fällig"
                    // at 22:15 before it had opened — while
                    // `MedicationScheduleSection.doseWindowLines` printed the
                    // declared band to the user verbatim. Do not restore the
                    // guard; a wrap is the only reading this pair has.
                    let startMinutes = minutes(start)
                    var endMinutes = minutes(end)
                    if endMinutes < startMinutes { endMinutes += 24 * 60 }
                    return DoseBand(
                        timeOfDay: time,
                        startMinutes: startMinutes,
                        endMinutes: endMinutes
                    )
                }
                let anchor = minutes(time)
                return DoseBand(
                    timeOfDay: time,
                    startMinutes: max(0, anchor - defaultOnTimeHalfWidthMinutes),
                    endMinutes: min(24 * 60 - 1, anchor + defaultOnTimeHalfWidthMinutes)
                )
            }
        }

        var start = minutes(entry.windowStart)
        var end = entry.windowEnd.map(minutes) ?? effectiveWindowEndMinutes(entry)
        if end == start {
            start = max(0, start - defaultOnTimeHalfWidthMinutes)
            end = min(24 * 60 - 1, end + defaultOnTimeHalfWidthMinutes)
        } else if end < start {
            end += 24 * 60
        }
        return [DoseBand(timeOfDay: entry.windowStart, startMinutes: start, endMinutes: end)]
    }

    // MARK: - Grace / window-end fallback

    /// Window-end in wall-clock minutes. When the schedule has no explicit
    /// `windowEnd`, derive it from the grace span the recurrence engine uses
    /// (`reminderGraceMinutes` → legacy `windowEnd - windowStart` → 60 min),
    /// so the overdue grace matches `MedicationRecurrenceEngine.graceSeconds`.
    static func effectiveWindowEndMinutes(_ entry: ScheduleEntry) -> Int {
        if let end = entry.windowEnd, minutes(end) != minutes(entry.windowStart) {
            return minutes(end)
        }
        // No explicit end OR a zero-length `windowStart == windowEnd` shape:
        // fall through to the engine grace. W-B179 — the zero-length case
        // previously returned `minutes(end) == startMins`, which the caller's
        // overnight-wrap then inflated to a full 24 h window ("Jetzt fällig"
        // around the clock). `graceSeconds` already maps a zero span to the
        // default grace (mirroring the server's `graceWindowMs`); use it.
        let graceMinutes = Int(MedicationRecurrenceEngine.graceSeconds(entry) / 60)
        return minutes(entry.windowStart) + graceMinutes
    }

    // MARK: - Cadence weekday gate

    /// Whether `entry`'s cadence fires on `now`'s weekday. Mirrors the web's
    /// `parseScheduleRecurrence(daysOfWeek)` day-of-week filter — only the
    /// weekday-constrained cadences gate; daily / rolling / interval cadences
    /// are treated as eligible "today" (the web reducer only checks the
    /// weekday set, leaving interval/rolling to the next-dose projector).
    static func firesToday(_ entry: ScheduleEntry, now: Date, calendar: Calendar) -> Bool {
        let weekdayIndex = calendar.component(.weekday, from: now) - 1 // Sun=0
        guard let today = Weekday(rawValue: weekdayIndex) else { return true }
        switch entry.cadence {
        case let .weekdays(days):
            return days.isEmpty || days.contains(today)
        case let .everyNWeeks(_, days):
            return days.isEmpty || days.contains(today)
        case let .legacy(days, _):
            guard let days, !days.isEmpty else { return true }
            return days.contains(today)
        case .daily, .monthly, .everyNMonths, .yearly, .rolling, .oneShot,
             .asNeeded, .cyclic:
            return true
        }
    }

    // MARK: - Minute helpers

    private static func minutes(_ time: TimeOfDay) -> Int {
        time.hour * 60 + time.minute
    }

    private static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func priority(_ status: MedicationWindowStatus) -> Int {
        switch status {
        case .inWindow: 3
        case .late: 2
        case .veryLate: 1
        }
    }
}
