import Foundation

/// **When the reminders for a medication come, in plain words** (server
/// 1.49.0 UX point 6, web `ReminderPlanLine`).
///
/// The stored dose times of the schedule, and for the current dose the
/// instants the server resolved (`complianceDisplay.currentDose` of
/// `GET /api/medications/{id}/compliance`, #191 final): when it is due,
/// overdue and missed. Nothing is computed on the device; without a current
/// dose only the times are named. Times read in the account's hour cycle
/// (``HLTimeFormat``), never as a fixed `HH:mm`.
enum MedicationReminderWords {
    /// **#191 (final) — the current dose as the server resolved it**
    /// (`complianceDisplay.currentDose`): its time and the three instants of
    /// its window. The app reads them and computes nothing.
    struct CurrentDose: Equatable, Sendable {
        let targetAt: Date
        let dueAt: Date?
        let overdueSince: Date?
        let missedAfter: Date?

        /// `nil` when the server names no current dose (`targetAt` null, or
        /// no `complianceDisplay` at all).
        init?(_ dose: ComplianceCurrentDose?) {
            guard let dose, let targetAt = dose.targetAt else { return nil }
            self.targetAt = targetAt
            dueAt = dose.dueAt
            overdueSince = dose.overdueSince
            missedAfter = dose.missedAfter
        }

        init(targetAt: Date, dueAt: Date?, overdueSince: Date?, missedAfter: Date?) {
            self.targetAt = targetAt
            self.dueAt = dueAt
            self.overdueSince = overdueSince
            self.missedAfter = missedAfter
        }
    }

    enum Summary: Equatable, Sendable {
        /// Doses are recorded automatically; no reminder is sent.
        case autoRecorded
        /// The medication's reminders are switched off.
        case remindersOff
        /// The dose times of a day, earliest first, and the current dose with
        /// its window (`nil` when the server names none).
        case schedule(times: [Int], current: CurrentDose?)

        /// Whether the phases can be adjusted from here: not for a medication
        /// whose doses are recorded automatically.
        var offersPhaseConfig: Bool {
            self != .autoRecorded
        }
    }

    // MARK: - Summary

    /// What to say for `medication`, or `nil` when the section shows nothing:
    /// as needed, kept as a record, paused or ended, or no dose time at all.
    static func summary(for medication: Medication, currentDose: ComplianceCurrentDose?) -> Summary? {
        guard !medication.asNeeded, medication.tracksIntake, medication.active,
              !medication.hasEndedCourseNow, medication.courseStatus != .ended else { return nil }
        let times = Array(Set(slotMinutes(of: medication.schedule))).sorted()
        guard !times.isEmpty else { return nil }
        if medication.autoMarkTaken == true { return .autoRecorded }
        if !medication.notificationsEnabled || medication.remindersActive == false { return .remindersOff }
        return .schedule(times: times, current: CurrentDose(currentDose))
    }

    /// Every stored dose time of the schedule, as minutes after midnight.
    /// As-needed entries have none.
    static func slotMinutes(of schedule: MedicationSchedule) -> [Int] {
        schedule.entries
            .filter { $0.cadence != .asNeeded }
            .flatMap { $0.effectiveTimes.map { $0.hour * 60 + $0.minute } }
    }

    // MARK: - Words

    /// The one or two sentences for `summary`.
    static func text(
        _ summary: Summary,
        locale: Locale = HLTimeFormat.current().formattingLocale,
        timeZone: TimeZone = .current
    ) -> String {
        switch summary {
        case .autoRecorded:
            return String(
                localized: "med.reminders.autoRecorded",
                defaultValue: "Doses are recorded automatically, so no reminders are sent."
            )
        case .remindersOff:
            return String(localized: "med.reminders.off", defaultValue: "Reminders are off for this medication.")
        case let .schedule(times, current):
            let clock = { (minute: Int) in HLTimeFormat.clock(minutesAfterMidnight: minute, locale: locale) }
            let list = times.map(clock).formatted(.list(type: .and).locale(locale))
            let timesSentence = times.count == 1
                ? String(
                    format: String(localized: "med.reminders.times.one", defaultValue: "Reminder for the dose at %@."),
                    list
                )
                : String(
                    format: String(localized: "med.reminders.times.many", defaultValue: "Reminders for the doses at %@."),
                    list
                )
            guard let current, let sentence = currentSentence(current, locale: locale, timeZone: timeZone) else {
                return timesSentence
            }
            return timesSentence + " " + sentence
        }
    }

    /// "Current dose 08:00: due from 07:00, overdue from 09:00, missed from
    /// 13:00." Only the instants the server sent; without any, nothing.
    static func currentSentence(_ dose: CurrentDose, locale: Locale, timeZone: TimeZone) -> String? {
        guard let due = dose.dueAt, let overdue = dose.overdueSince, let missed = dose.missedAfter else { return nil }
        let clock = { (date: Date) in HLTimeFormat.shortTime(date, locale: locale, timeZone: timeZone) }
        return String(
            format: String(
                localized: "med.reminders.current",
                defaultValue: "Current dose %1$@: due from %2$@, overdue from %3$@, missed from %4$@."
            ),
            clock(dose.targetAt),
            clock(due),
            clock(overdue),
            clock(missed)
        )
    }
}
