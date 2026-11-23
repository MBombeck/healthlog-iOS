import Foundation

// MARK: - Plan

/// The medication's plan as text for the detail page's object card (Z16 §3):
/// the cadence line and the dose windows the server grades on-time against.
///
/// v1.39.1 — for a medication kept as a record the schedule is information
/// only. The hero's "Nur dokumentiert" mark says so; no line repeats it.
enum MedicationPlanText {
    /// Handbook §3.2 single-line plan composition: the cadence prefix, the
    /// optional weekday list and the optional time list. `nil` when neither
    /// times nor weekdays are configured: no plan fact rather than one saying
    /// "Täglich" about nothing.
    static func line(_ schedule: MedicationSchedule) -> String? {
        let hasWeekdays = !(schedule.weekdays?.isEmpty ?? true)
        guard !schedule.times.isEmpty || hasWeekdays else { return nil }
        let cadence = if schedule.intervalWeeks > 1 {
            String(format: String(localized: "Every %d weeks"), schedule.intervalWeeks)
        } else if hasWeekdays {
            String(localized: "Weekly")
        } else {
            String(localized: "Daily")
        }
        var parts = [cadence]
        if hasWeekdays, let days = schedule.weekdays {
            parts.append(weekdayLabel(days))
        }
        if !schedule.times.isEmpty {
            parts.append(ClockTimeText.list(schedule.times))
        }
        return parts.joined(separator: " ")
    }

    /// The dose windows, one per time of day, joined on one line; `nil`
    /// without any.
    static func doseWindows(_ schedule: MedicationSchedule) -> String? {
        var seen = Set<String>()
        let lines = schedule.entries
            .compactMap(\.doseWindows)
            .flatMap { $0 }
            .filter { seen.insert($0.timeOfDay).inserted }
            .map { window in
                "\(ClockTimeText.wire(window.timeOfDay)): " + String(
                    format: String(localized: "med.schedule.dose_window"),
                    ClockTimeText.wire(window.start),
                    ClockTimeText.wire(window.end)
                )
            }
        return HLRowDetail.joined(lines)
    }

    private static func weekdayLabel(_ days: Set<Weekday>) -> String {
        let sorted = days.sorted { $0.rawValue < $1.rawValue }
        let calendar = Calendar.current
        // Full weekday names ('Mittwoch') for the single-day
        // common case, short names ('Mo, Di, Mi') only when there are
        // multiple weekdays so the line still fits at iPhone 393 pt.
        let symbols = sorted.count == 1 ? calendar.standaloneWeekdaySymbols : calendar.shortStandaloneWeekdaySymbols
        let labels = sorted.map { day -> String in
            // Server convention: Sunday=0. The calendar's symbol arrays are
            // Sunday-first too, so the indices match 1:1.
            symbols[day.rawValue]
        }
        return labels.joined(separator: ", ")
    }
}
