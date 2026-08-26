import Foundation

/// **v0.10 R1 §3.2 — pure Swift mirror of the server's canonical recurrence
/// engine (`src/lib/medications/scheduling/recurrence.ts`).**
///
/// Single source of truth on iOS for "what dose slots does this schedule emit
/// between A and B?" Dispatches in the same strict priority order the server
/// uses (the first matching tier wins):
///
///   1. **One-shot** (`medication.oneShot == true`) — a single slot at the
///      `startsOn ?? createdAt` anchor, one per `timesOfDay` entry.
///   2. **Rolling** (`cadence == .rolling`) — the next slot is
///      `(lastIntakeAt ?? startsOn ?? createdAt) + N days`. Only the
///      immediately-next slot exists forward; past rolling slots are
///      historical intakes, not predicted slots. A skip never advances the
///      anchor (skip ≠ take).
///   3. **Calendar** (`daily` / `weekdays` / `everyNWeeks` / `monthly` /
///      `everyNMonths` / `yearly`) — an unbounded forward grid, anchored on
///      `startsOn ?? createdAt`, floored by `startsOn`, capped by `endsOn`,
///      with the multi-week / multi-month phase anchored to the start.
///   4. **Legacy** (`.legacy`) — pre-v1.5 weekday-subset + `intervalWeeks`,
///      honouring the `intervalWeeks > 1` stride the old worker dropped.
///
/// All time-of-day application happens in the **user's IANA timezone** (from
/// the server profile, NOT the device TZ — R1 risk 7), via a `Calendar`
/// pinned to that zone. `Calendar`'s wall-clock arithmetic is DST-correct and
/// matches the server's two-pass solver behaviour (spring-forward forwards a
/// non-existent local time to the next valid minute).
///
/// Pure, `Sendable`, no I/O. The caller fetches `lastIntakeAt`
/// (`medication.lastTakenAt`) and threads it through.
public enum MedicationRecurrenceEngine {
    /// One emitted dose slot.
    public struct Occurrence: Sendable, Hashable {
        /// The start instant of this occurrence (time-of-day applied in the
        /// user timezone, DST-correct).
        public let at: Date
        /// The grace-window end instant — `reminderGraceMinutes` when set,
        /// else the legacy `windowEnd - windowStart` span, else 60 min.
        public let graceUntil: Date
        /// Which `timesOfDay` entry this corresponds to (the `HH:mm` string)
        /// so the UI can label "Morning" vs "Evening".
        public let timeOfDay: TimeOfDay

        public init(at: Date, graceUntil: Date, timeOfDay: TimeOfDay) {
            self.at = at
            self.graceUntil = graceUntil
            self.timeOfDay = timeOfDay
        }
    }

    /// The recurrence inputs the engine needs from the parent medication.
    public struct Context: Sendable {
        public let startsOn: Date?
        public let endsOn: Date?
        public let oneShot: Bool
        public let createdAt: Date?
        /// Latest non-skipped intake (`medication.lastTakenAt`). Rolling anchor.
        public let lastIntakeAt: Date?
        /// The user's IANA timezone identifier (e.g. "Europe/Berlin").
        public let timeZone: TimeZone
        /// **v0.10 W-Meds-A2 (v1.7.0 SB-SCHED-3) — server-computed `nextDueAt`.**
        /// When non-nil, `nextOccurrence(after:)` PREFERS this authoritative
        /// instant over the locally-projected next slot (removes the two-engine
        /// parity risk). `nil` for PRN + against the current server → the local
        /// engine computes the next occurrence as before. Does NOT affect the
        /// `occurrences(in:)` grid (compliance / derived-intakes), only the
        /// single forward reminder slot the schedulers consume.
        public let serverNextDueAt: Date?

        public init(
            startsOn: Date?,
            endsOn: Date?,
            oneShot: Bool,
            createdAt: Date?,
            lastIntakeAt: Date?,
            timeZone: TimeZone,
            serverNextDueAt: Date? = nil
        ) {
            self.startsOn = startsOn
            self.endsOn = endsOn
            self.oneShot = oneShot
            self.createdAt = createdAt
            self.lastIntakeAt = lastIntakeAt
            self.timeZone = timeZone
            self.serverNextDueAt = serverNextDueAt
        }

        /// Build a `Context` straight from a `Medication`. `now` is the
        /// ultimate createdAt fallback when the wire omitted it — anchoring a
        /// rolling/legacy schedule on "now" is the safe default (the next slot
        /// is then `now + N`, never a historical backlog).
        public init(medication: Medication, timeZone: TimeZone, now: Date = .now) {
            self.init(
                startsOn: medication.startsOn,
                endsOn: medication.endsOn,
                oneShot: medication.oneShot,
                createdAt: medication.createdAt ?? now,
                lastIntakeAt: medication.lastTakenAt,
                timeZone: timeZone,
                serverNextDueAt: medication.nextDueAt
            )
        }
    }

    /// Whether a cadence is "single-slot" — i.e. the schedulers arm exactly one
    /// forward reminder for it (a one-off `.fixed`/`.once`), rather than a
    /// recurring OS rule. These are the kinds for which the server `nextDueAt`
    /// override applies. Recurring kinds (daily / weekday-weekly / everyNWeeks
    /// with interval 1) arm recurring rules and don't consult the fixed slot.
    private static func isSingleSlotCadence(_ cadence: Cadence, oneShot: Bool) -> Bool {
        if oneShot { return true }
        switch cadence {
        case .rolling, .oneShot, .monthly, .everyNMonths, .yearly, .cyclic:
            return true
        case let .everyNWeeks(interval, _):
            return interval > 1
        case let .legacy(days, intervalWeeks):
            // Legacy with a weekday set + interval 1 is recurring; otherwise
            // (interval > 1, or no weekday set with interval > 1) it's a fixed
            // next-occurrence slot — mirror the scheduler projection branches.
            if let days, !days.isEmpty, intervalWeeks <= 1 { return false }
            return intervalWeeks > 1
        case .daily, .weekdays, .asNeeded:
            return false
        }
    }

    private static let dayInterval: TimeInterval = 24 * 60 * 60
    private static let defaultGraceMinutes = 60
    private static let maxChunks = 80

    // MARK: - Public API

    /// Every occurrence in `[from, to]` (both ends inclusive) in chronological
    /// order. Pure: no I/O.
    public static func occurrences(
        in range: ClosedRange<Date>,
        entry: ScheduleEntry,
        context: Context
    ) -> [Occurrence] {
        let from = range.lowerBound
        let to = range.upperBound
        guard to >= from else { return [] }

        // PRN / as-needed (v1.7.0 SB-SCHED-5) — never projects an occurrence.
        // Intakes stay loggable, but the engine emits nothing → no
        // expected-count, no reminder slot, no `nextDueAt`.
        if entry.cadence == .asNeeded { return [] }
        if context.oneShot || entry.cadence == .oneShot {
            return expandOneShot(entry: entry, context: context, from: from, to: to)
        }
        if case let .rolling(intervalDays) = entry.cadence {
            return expandRolling(entry: entry, intervalDays: intervalDays, context: context, from: from, to: to)
        }
        return expandCalendar(entry: entry, context: context, from: from, to: to)
    }

    /// The next occurrence strictly after `after`, or `nil` when the schedule
    /// has terminated (one-shot anchor past; `endsOn` crossed; rolling with no
    /// anchor). Walks forward in 90-day chunks for calendar cadences, capped
    /// at `maxChunks` and a 10-year hard cap so a pathological schedule never
    /// spins.
    public static func nextOccurrence(
        after: Date,
        entry: ScheduleEntry,
        context: Context
    ) -> Occurrence? {
        // PRN / as-needed never has a next occurrence.
        if entry.cadence == .asNeeded { return nil }

        // v1.7.0 SB-SCHED-3 — prefer the server-computed `nextDueAt` over the
        // local projection for the single-slot cadences (the ones the
        // schedulers arm as a one-off `.fixed`/`.once` reminder). This is the
        // authoritative next instant; using it removes the two-engine
        // parity-drift risk. Recurring cadences (daily/weekly) arm recurring OS
        // rules, not this fixed slot, so the override is scoped to single-slot
        // kinds. The override still honours the `after` floor + `endsOn` cap.
        if let serverNext = context.serverNextDueAt,
           serverNext > after,
           isSingleSlotCadence(entry.cadence, oneShot: context.oneShot)
        {
            if let endsOn = context.endsOn, serverNext > endOfUtcDay(endsOn, context.timeZone) {
                return nil
            }
            let time = entry.timesOfDay.first ?? entry.windowStart
            return makeOccurrence(at: serverNext, time: time, entry: entry)
        }

        let hardCap = after.addingTimeInterval(365 * 10 * dayInterval)
        let limit: Date = if let endsOn = context.endsOn {
            min(endOfUtcDay(endsOn, context.timeZone), hardCap)
        } else {
            hardCap
        }
        let cursorStart = after.addingTimeInterval(1)

        // One-shot + rolling are single-slot — fast path.
        if context.oneShot || entry.cadence == .oneShot {
            return occurrences(in: cursorStart ... limit, entry: entry, context: context)
                .first { $0.at > after }
        }
        if case .rolling = entry.cadence {
            return occurrences(in: cursorStart ... limit, entry: entry, context: context)
                .first { $0.at > after }
        }

        // Calendar cadences — walk 90-day chunks.
        let chunk: TimeInterval = 90 * dayInterval
        var cursor = cursorStart
        var chunks = 0
        while cursor <= limit {
            if chunks >= maxChunks { return nil }
            chunks += 1
            let chunkEnd = min(cursor.addingTimeInterval(chunk), limit)
            let slots = occurrences(in: cursor ... chunkEnd, entry: entry, context: context)
            if let hit = slots.first(where: { $0.at > after }) { return hit }
            cursor = chunkEnd.addingTimeInterval(1)
        }
        return nil
    }

    /// Does this schedule emit an occurrence on the user-local calendar day
    /// containing `day`? Used by the derived-intakes synth path.
    public static func firesOn(
        day: Date,
        entry: ScheduleEntry,
        context: Context
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        // Half-open [start, end) → closed [start, end - 1s].
        return !occurrences(
            in: start ... end.addingTimeInterval(-1),
            entry: entry,
            context: context
        ).isEmpty
    }

    // MARK: - One-shot

    private static func expandOneShot(
        entry: ScheduleEntry,
        context: Context,
        from: Date,
        to: Date
    ) -> [Occurrence] {
        let anchor = context.startsOn ?? context.createdAt ?? from
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let day = calendar.startOfDay(for: anchor)
        var slots: [Occurrence] = []
        for time in entry.effectiveTimes {
            guard let at = applyTime(time, toDay: day, calendar: calendar) else { continue }
            if at < from || at > to { continue }
            slots.append(makeOccurrence(at: at, time: time, entry: entry))
        }
        return slots.sorted { $0.at < $1.at }
    }

    // MARK: - Rolling

    private static func expandRolling(
        entry: ScheduleEntry,
        intervalDays: Int,
        context: Context,
        from: Date,
        to: Date
    ) -> [Occurrence] {
        guard intervalDays > 0 else { return [] }
        let anchor = context.lastIntakeAt ?? context.startsOn ?? context.createdAt ?? from
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        guard let nextDue = calendar.date(byAdding: .day, value: intervalDays, to: anchor) else {
            return []
        }
        // endsOn cap.
        if let endsOn = context.endsOn, nextDue > endOfUtcDay(endsOn, context.timeZone) {
            return []
        }
        let time = entry.timesOfDay.first ?? entry.windowStart
        let day = calendar.startOfDay(for: nextDue)
        guard let at = applyTime(time, toDay: day, calendar: calendar) else { return [] }
        if at < from || at > to { return [] }
        return [makeOccurrence(at: at, time: time, entry: entry)]
    }

    // MARK: - Calendar (daily / weekly / monthly / yearly / legacy)

    private static func expandCalendar(
        entry: ScheduleEntry,
        context: Context,
        from: Date,
        to: Date
    ) -> [Occurrence] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone

        let anchor = context.startsOn ?? context.createdAt ?? from
        let startsOnFloor = context.startsOn.map { calendar.startOfDay(for: $0) }
        let endsOnCap = context.endsOn.map { endOfUtcDay($0, context.timeZone) }

        // Iterate every user-local day in [from-1d, to+1d] so a time-of-day
        // that lands in [from, to] after applying HH:mm is still caught.
        guard
            let iterStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: from)),
            let iterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) else { return [] }

        let times = entry.effectiveTimes
        var slots: [Occurrence] = []
        var day = calendar.startOfDay(for: iterStart)
        let endDay = calendar.startOfDay(for: iterEnd)

        while day <= endDay {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? endDay.addingTimeInterval(dayInterval)
            }
            if let floor = startsOnFloor, day < floor { continue }
            guard dayMatches(day, cadence: entry.cadence, anchor: anchor, calendar: calendar) else { continue }
            for time in times {
                guard let at = applyTime(time, toDay: day, calendar: calendar) else { continue }
                if at < from || at > to { continue }
                // endsOn cap — the occurrence instant must fall on/before the
                // end of the endsOn day (UTC, matching the server `@db.Date`
                // boundary).
                if let cap = endsOnCap, at > cap { continue }
                slots.append(makeOccurrence(at: at, time: time, entry: entry))
            }
        }
        return slots.sorted { $0.at < $1.at }
    }

    /// Whether the cadence fires on the user-local day `day` (a start-of-day
    /// instant in the user TZ).
    private static func dayMatches(
        _ day: Date,
        cadence: Cadence,
        anchor: Date,
        calendar: Calendar
    ) -> Bool {
        switch cadence {
        case .daily:
            return true

        case let .weekdays(days):
            return days.isEmpty || days.contains(weekday(of: day, calendar))

        case let .everyNWeeks(interval, days):
            if !days.isEmpty, !days.contains(weekday(of: day, calendar)) { return false }
            return weekPhaseMatches(day, anchor: anchor, interval: max(1, interval), calendar: calendar)

        case .monthly, .everyNMonths, .yearly:
            return monthlyClusterMatches(day, cadence: cadence, anchor: anchor, calendar: calendar)

        case let .legacy(days, intervalWeeks):
            if let days, !days.isEmpty, !days.contains(weekday(of: day, calendar)) { return false }
            guard intervalWeeks > 1 else { return true }
            return weekPhaseMatches(day, anchor: anchor, interval: intervalWeeks, calendar: calendar)

        case let .cyclic(weeksOn, weeksOff):
            // Fire every day inside an on-week, counting whole weeks from the
            // medication anchor — `startsOn ?? createdAt`, which is what the
            // server counts from too. 09-14 removed the per-schedule
            // `cycleAnchor` preference: it was read from a wire key that does
            // not exist, so it was always nil, and had it ever been non-nil it
            // would have silently overridden the only anchor the server honours.
            return cyclicOnWeek(
                day,
                weeksOn: weeksOn,
                weeksOff: weeksOff,
                anchor: anchor,
                calendar: calendar
            )

        case .rolling, .oneShot, .asNeeded:
            return false
        }
    }

    /// Day-match for the month/year cluster (`monthly` / `everyNMonths` /
    /// `yearly`). Extracted from `dayMatches` to keep that switch under the
    /// cyclomatic-complexity budget. Non-cluster cadences never reach here.
    private static func monthlyClusterMatches(
        _ day: Date,
        cadence: Cadence,
        anchor: Date,
        calendar: Calendar
    ) -> Bool {
        switch cadence {
        case let .monthly(targetDay):
            return calendar.component(.day, from: day) == clampedMonthDay(targetDay, in: day, calendar)
        case let .everyNMonths(interval, targetDay):
            guard calendar.component(.day, from: day) == clampedMonthDay(targetDay, in: day, calendar) else {
                return false
            }
            return monthPhaseMatches(day, anchor: anchor, interval: max(1, interval), calendar: calendar)
        case let .yearly(month, targetDay):
            return calendar.component(.month, from: day) == month
                && calendar.component(.day, from: day) == clampedMonthDay(targetDay, in: day, calendar)
        default:
            return false
        }
    }

    /// Whether `day` falls inside an on-week of a cyclic on/off schedule.
    /// Counts whole weeks from `anchor`'s Sunday-rooted week; the cycle period
    /// is `weeksOn + weeksOff`. A `weeksOff ≤ 0` schedule is always on.
    ///
    /// `anchor` is the medication's `startsOn ?? createdAt`. That is the only
    /// anchor there is — the server counts the same phase from the same date
    /// (`src/lib/medications/scheduling/recurrence.ts:246`) and publishes no
    /// per-schedule anchor.
    private static func cyclicOnWeek(
        _ day: Date,
        weeksOn: Int,
        weeksOff: Int,
        anchor: Date,
        calendar: Calendar
    ) -> Bool {
        guard weeksOn > 0 else { return false }
        let period = weeksOn + weeksOff
        guard period > weeksOn else { return true } // no off-weeks → always on
        let dayWeek = startOfSundayWeek(day, calendar)
        let anchorWeek = startOfSundayWeek(calendar.startOfDay(for: anchor), calendar)
        let weeks = Int((dayWeek.timeIntervalSince(anchorWeek) / (7 * dayInterval)).rounded())
        let phase = ((weeks % period) + period) % period
        return phase < weeksOn
    }
}

/// Phase / time-of-day / day-boundary helpers split into an extension so the
/// primary `enum` body stays within the type-body-length budget.
extension MedicationRecurrenceEngine {
    // MARK: - Phase helpers

    /// Multi-week phase, anchored on the week containing `anchor`. The server
    /// roots weeks on Sunday; mirror that with a Sunday-rooted week start so
    /// the parity vectors line up.
    private static func weekPhaseMatches(
        _ day: Date,
        anchor: Date,
        interval: Int,
        calendar: Calendar
    ) -> Bool {
        let dayWeek = startOfSundayWeek(day, calendar)
        let anchorWeek = startOfSundayWeek(calendar.startOfDay(for: anchor), calendar)
        let weeks = Int((dayWeek.timeIntervalSince(anchorWeek) / (7 * dayInterval)).rounded())
        let phase = ((weeks % interval) + interval) % interval
        return phase == 0
    }

    private static func monthPhaseMatches(
        _ day: Date,
        anchor: Date,
        interval: Int,
        calendar: Calendar
    ) -> Bool {
        let anchorDay = calendar.startOfDay(for: anchor)
        let a = calendar.dateComponents([.year, .month], from: anchorDay)
        let d = calendar.dateComponents([.year, .month], from: day)
        guard let ay = a.year, let am = a.month, let dy = d.year, let dm = d.month else { return false }
        let months = (dy - ay) * 12 + (dm - am)
        let phase = ((months % interval) + interval) % interval
        return phase == 0
    }

    private static func startOfSundayWeek(_ day: Date, _ calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        // `.weekday` is 1=Sun…7=Sat; subtract (weekday-1) days to reach Sunday.
        let weekdayIndex = calendar.component(.weekday, from: start) - 1
        return calendar.date(byAdding: .day, value: -weekdayIndex, to: start) ?? start
    }

    private static func weekday(of day: Date, _ calendar: Calendar) -> Weekday {
        // `.weekday` 1=Sun…7=Sat → our Weekday raw 0=Sun…6=Sat.
        let raw = calendar.component(.weekday, from: day) - 1
        return Weekday(rawValue: max(0, min(6, raw))) ?? .sun
    }

    /// Clamp a target day-of-month to the days the month actually has (so a
    /// `BYMONTHDAY=31` schedule still fires on the 30th / 28th — matching the
    /// rrule lib's behaviour of skipping non-existent days is the server's
    /// choice, but for the wizard subset day ≤ 28 is the common case; clamping
    /// here keeps short months sane without inventing extra fires).
    private static func clampedMonthDay(_ target: Int, in day: Date, _ calendar: Calendar) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: day) else { return target }
        return min(target, range.count)
    }

    // MARK: - Time-of-day + grace

    /// Apply an `HH:mm` to a user-local day, returning the UTC instant.
    ///
    /// Ports the server's `applyTimeOfDayToDate` two-pass offset solver exactly
    /// (rather than `Calendar.date(bySettingHour:)`) so the DST spring-forward
    /// behaviour matches: a non-existent local time (02:30 on the Berlin
    /// spring-forward day) is resolved by forwarding to 03:30 wall-clock
    /// (= 01:30 UTC) — the offset is preserved, not snapped to the gap edge.
    /// `Calendar.date(bySettingHour:)` instead snaps to 03:00 (01:00 UTC),
    /// which diverges from the server engine.
    private static func applyTime(_ time: TimeOfDay, toDay day: Date, calendar: Calendar) -> Date? {
        // The wall-clock Y/M/D of `day` in the user timezone.
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
            return nil
        }

        /// First guess: treat the wall clock as if it were UTC, then correct by
        /// the zone's offset at that approximate instant. Two passes converge
        /// across any DST transition (the second pass adjusts the offset).
        func utcGuess() -> Date? {
            var utc = DateComponents()
            utc.year = year
            utc.month = month
            utc.day = dayOfMonth
            utc.hour = time.hour
            utc.minute = time.minute
            utc.second = 0
            return utcCalendar.date(from: utc)
        }
        guard var guess = utcGuess() else { return nil }
        for _ in 0 ..< 2 {
            let offset = TimeInterval(calendar.timeZone.secondsFromGMT(for: guess))
            guard let base = utcGuess() else { return nil }
            guess = base.addingTimeInterval(-offset)
        }
        return guess
    }

    /// A UTC-pinned calendar reused for the two-pass time-of-day solver.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    private static func makeOccurrence(at: Date, time: TimeOfDay, entry: ScheduleEntry) -> Occurrence {
        Occurrence(at: at, graceUntil: at.addingTimeInterval(graceSeconds(entry)), timeOfDay: time)
    }

    /// Resolve the grace window: `reminderGraceMinutes` → legacy
    /// `windowEnd - windowStart` span → 60 min. Mirrors the server's
    /// `graceWindowMs`, including the overnight-window wrap.
    static func graceSeconds(_ entry: ScheduleEntry) -> TimeInterval {
        if let minutes = entry.reminderGraceMinutes {
            return TimeInterval(minutes) * 60
        }
        let startMin = entry.windowStart.hour * 60 + entry.windowStart.minute
        guard let end = entry.windowEnd else {
            return TimeInterval(defaultGraceMinutes) * 60
        }
        let endMin = end.hour * 60 + end.minute
        var span = endMin - startMin
        if span < 0 { span += 24 * 60 } // overnight window
        if span == 0 { span = defaultGraceMinutes }
        return TimeInterval(span) * 60
    }

    // MARK: - UTC day boundary (endsOn cap)

    /// End-of-day for the `endsOn` cap. The server uses `endOfUtcDay`; mirror
    /// it so the cap aligns with the server's `@db.Date` UTC-midnight column.
    private static func endOfUtcDay(_ date: Date, _: TimeZone) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let start = utc.startOfDay(for: date)
        return start.addingTimeInterval(dayInterval - 0.001)
    }
}
