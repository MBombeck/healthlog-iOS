import Foundation

/// #119 / #126 P2 (server v1.40.1) — the doctor report's pulse row.
///
/// The server's rule: a day of pulse is the mean of its local hours' means,
/// and a window is the mean of its days; count, min and max stay over every
/// reading. The report used to average the raw readings it had in memory, so
/// a busy hour of a workout outweighed a quiet night. Now:
///
/// - with the server's day values (``DailyPulseValue``): mean and median over
///   those days, min and max over the days' own min and max, count summed;
/// - without them (offline): the same rule applied to the readings
///   in the window, hours in the account's calendar, so the row never falls
///   back to a plain average of readings.
enum DoctorReportPulse {
    static func row(
        serverDays: [DailyPulseValue]?,
        readings: [Measurement],
        calendar: Calendar
    ) -> DoctorReportSpec.VitalsSummary.Row? {
        if let serverDays, !serverDays.isEmpty {
            return row(fromDays: serverDays)
        }
        return row(fromReadings: readings, calendar: calendar)
    }

    static func row(fromDays days: [DailyPulseValue]) -> DoctorReportSpec.VitalsSummary.Row? {
        let means = days.map(\.mean)
        guard !means.isEmpty else { return nil }
        let lows = days.map { $0.min ?? $0.mean }
        let highs = days.map { $0.max ?? $0.mean }
        return DoctorReportSpec.VitalsSummary.Row(
            kind: .pulse,
            mean: means.reduce(0, +) / Double(means.count),
            median: median(of: means),
            min: lows.min() ?? 0,
            max: highs.max() ?? 0,
            count: days.reduce(0) { $0 + Swift.max($1.count, 0) },
            secondaryMean: nil
        )
    }

    /// The server's rule over raw readings: hour means, then day means, then
    /// the mean of the days. Count, min and max over every reading.
    static func row(fromReadings readings: [Measurement], calendar: Calendar) -> DoctorReportSpec.VitalsSummary.Row? {
        let pulse = readings.filter { $0.kind == .pulse }
        guard !pulse.isEmpty else { return nil }
        let days = dayMeans(of: pulse, calendar: calendar)
        guard !days.isEmpty else { return nil }
        let values = pulse.map(\.primaryValue)
        return DoctorReportSpec.VitalsSummary.Row(
            kind: .pulse,
            mean: days.reduce(0, +) / Double(days.count),
            median: median(of: days),
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            count: values.count,
            secondaryMean: nil
        )
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// One mean per local day, each the mean of that day's hour means.
    static func dayMeans(of readings: [Measurement], calendar: Calendar) -> [Double] {
        let byHour = Dictionary(grouping: readings) { reading in
            calendar.dateInterval(of: .hour, for: reading.recordedAt)?.start ?? reading.recordedAt
        }
        let hourMeans: [(hour: Date, mean: Double)] = byHour.map { hour, rows in
            (hour, rows.map(\.primaryValue).reduce(0, +) / Double(rows.count))
        }
        let byDay = Dictionary(grouping: hourMeans) { calendar.startOfDay(for: $0.hour) }
        return byDay.keys.sorted().compactMap { day in
            guard let hours = byDay[day], !hours.isEmpty else { return nil }
            return hours.map(\.mean).reduce(0, +) / Double(hours.count)
        }
    }
}
