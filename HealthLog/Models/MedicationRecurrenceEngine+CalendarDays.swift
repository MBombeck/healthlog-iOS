import Foundation

/// **R1 (server 1.39.3, A1 on #115) — calendar days for the recurrence engine.**
///
/// Split out of `MedicationRecurrenceEngine.swift` (file_length discipline).
/// `startsOn` / `endsOn` are calendar dates carried as UTC midnight; these
/// helpers turn them into days in the profile calendar and only then into
/// instants, the way the server's `civilDayOfDate` / `endOfCivilDayInstant` do.
extension MedicationRecurrenceEngine {
    // MARK: - Calendar days (R1, server 1.39.3)

    /// A gregorian calendar pinned to the profile zone of `context`.
    static func profileCalendar(_ context: Context) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        return calendar
    }

    /// The calendar day a `YYYY-MM-DD` course date names, as the local start of
    /// that day in `calendar`'s zone.
    ///
    /// `startsOn` / `endsOn` are dates carried as UTC midnight (`@db.Date`).
    /// The day is read from the UTC year, month and day and only then placed
    /// in the profile zone — never by reading the instant in that zone, which
    /// west of UTC is the evening before. Built from local noon so a zone whose
    /// clocks skip midnight itself still yields that day.
    static func courseDay(_ date: Date, calendar: Calendar) -> Date? {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        var noon = DateComponents()
        noon.year = parts.year
        noon.month = parts.month
        noon.day = parts.day
        noon.hour = 12
        return calendar.date(from: noon).map { calendar.startOfDay(for: $0) }
    }

    /// The schedule's first day: the `startsOn` calendar day, else the local
    /// day the `createdAt` instant falls on (an instant IS read on the clock).
    static func anchorDay(_ context: Context, calendar: Calendar, fallback: Date) -> Date {
        if let startsOn = context.startsOn, let day = courseDay(startsOn, calendar: calendar) {
            return day
        }
        return calendar.startOfDay(for: context.createdAt ?? fallback)
    }

    /// The `endsOn` calendar day (local start of day), or `nil` for a chronic
    /// medication.
    static func courseEndDay(_ context: Context, calendar: Calendar) -> Date? {
        context.endsOn.flatMap { courseDay($0, calendar: calendar) }
    }

    /// The last instant of the `endsOn` day on the profile clock — where the
    /// server caps the next-due walk (`endOfCivilDayInstant`). The old cap was
    /// the end of the UTC day, which west of UTC ended the course in the local
    /// afternoon and dropped the evening dose.
    static func endOfCourse(_ context: Context) -> Date? {
        let calendar = profileCalendar(context)
        guard let endDay = courseEndDay(context, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: endDay) else { return nil }
        return next.addingTimeInterval(-0.001)
    }

    /// The first instant of the `startsOn` day on the profile clock, or `nil`
    /// when the medication has no start date.
    static func startOfCourse(_ context: Context) -> Date? {
        context.startsOn.flatMap { courseDay($0, calendar: profileCalendar(context)) }
    }

    /// Whether an OS-repeating daily/weekly rule may stand in for this
    /// schedule at `now`. Such a rule has no first and no last day, so it fits
    /// only once the start day has begun and while the `endsOn` day lies beyond
    /// `endHorizon` — closer than that, the caller arms single occurrences from
    /// this engine, which stop on the last course day. Every reconcile
    /// re-evaluates, so a long course switches over as its end approaches.
    static func repeatingRuleFits(context: Context, now: Date, endHorizon: TimeInterval) -> Bool {
        if let start = startOfCourse(context), start > now { return false }
        if let end = endOfCourse(context), end <= now.addingTimeInterval(endHorizon) { return false }
        return true
    }
}
