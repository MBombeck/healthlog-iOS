import SwiftUI

// MARK: - Schedule

struct ScheduleSection: View {
    let schedule: MedicationSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("Plan")
            HLCard {
                // v0.6.1 Y2 — single-line plan summary (handbook §3.2 +
                // D-025). Operator brief 2026-05-22: 'Bei Trulicity Plan
                // ganz unten: da steht jetzt 08:00 Mittwoch, das ist 2
                // Zeilen. Eigentlich macht es ja Sinn wenn das wöchentlich
                // ist Wöchentlich Mittwoch 08:00.'
                //
                // Compose one Text with calendar SF Symbol leading. Three
                // shapes:
                //
                //   - 'Wöchentlich Mittwoch 08:00'        (weekly + day + time)
                //   - 'Alle 2 Wochen Mittwoch 08:00'      (multi-week interval)
                //   - 'Täglich 08:00 · 14:00'             (daily, no weekdays)
                //   - 'Wöchentlich Mittwoch'              (no times, just days)
                //   - 'Kein Zeitplan konfiguriert.'       (empty)
                //
                // Wired in a single HStack so the SF Symbol stays glued to
                // the label and lineLimit(1) keeps the row on one row at
                // iPhone 393 pt.
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HStack(spacing: HLSpace.sm) {
                        // v0.6.1.2 Y4 (D-024) — calendar glyph collapses
                        // from .tint to HLText.secondary mono.
                        Image(systemName: "calendar")
                            .foregroundStyle(HLText.secondary)
                            .accessibilityHidden(true)
                        Text(scheduleLine)
                            .font(.hlBody)
                            .foregroundStyle(scheduleLineIsEmpty ? HLText.secondary : HLText.primary)
                            .monospacedDigit()
                            .lineLimit(2)
                            .accessibilityLabel(Text(scheduleLine))
                    }
                    // W3-MEDCONTRACT (v0.14.8) — per-dose on-time windows
                    // (v1.15.18 `doseWindows`): show the explicit band the
                    // server grades on-time against, when configured.
                    ForEach(doseWindowLines, id: \.self) { line in
                        Text(line)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// One caption line per configured per-dose window ("08:00 ·
    /// Einnahmefenster 07:30–09:00"), de-duplicated by dose time. Empty
    /// when no schedule carries explicit windows (server default ±1 h —
    /// nothing to show).
    private var doseWindowLines: [String] {
        var seen = Set<String>()
        return schedule.entries
            .compactMap(\.doseWindows)
            .flatMap { $0 }
            .filter { seen.insert($0.timeOfDay).inserted }
            .map { window in
                "\(window.timeOfDay) · " + String(
                    format: String(localized: "med.schedule.dose_window"),
                    window.start,
                    window.end
                )
            }
    }

    /// v0.6.1 Y2 — handbook §3.2 single-line plan composition. Returns one
    /// localised string assembled from the cadence prefix, optional
    /// weekday list, and optional time list. Falls back to the empty-state
    /// copy when no schedule components are configured.
    private var scheduleLine: String {
        let hasTimes = !schedule.times.isEmpty
        let hasWeekdays = !(schedule.weekdays?.isEmpty ?? true)
        if !hasTimes, !hasWeekdays {
            return String(localized: "No schedule configured.")
        }
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
        if hasTimes {
            parts.append(timesLabel)
        }
        return parts.joined(separator: " ")
    }

    private var scheduleLineIsEmpty: Bool {
        schedule.times.isEmpty && (schedule.weekdays?.isEmpty ?? true)
    }

    private var timesLabel: String {
        schedule.times
            .sorted()
            .map { String(format: "%02d:%02d", $0.hour, $0.minute) }
            .joined(separator: " · ")
    }

    /// v0.11 perf: hoist the weekday-symbol formatter to a single shared
    /// instance instead of allocating a `DateFormatter` on every row render.
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter
    }()

    private func weekdayLabel(_ days: Set<Weekday>) -> String {
        let sorted = days.sorted { $0.rawValue < $1.rawValue }
        let formatter = Self.weekdayFormatter
        // v0.6.1 Y2 — full weekday names ('Mittwoch') for the single-day
        // common case, short names ('Mo · Di · Mi') only when there are
        // multiple weekdays so the row still fits at iPhone 393 pt.
        let symbols = sorted.count == 1 ? formatter.standaloneWeekdaySymbols : formatter.shortStandaloneWeekdaySymbols
        let labels = sorted.map { day -> String in
            // Server convention: Sunday=0. DateFormatter symbol arrays
            // are also Sunday-first → indexing matches 1:1.
            symbols?[day.rawValue] ?? formatter.shortWeekdaySymbols[day.rawValue]
        }
        return labels.joined(separator: " · ")
    }
}
