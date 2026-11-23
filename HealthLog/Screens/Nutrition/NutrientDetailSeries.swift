import Foundation

/// What the nutrient page shows from one dense day series, kept out of the
/// view so the order and the honesty rules stay testable. The server sends
/// every day of the window and `0` for a day without data, so `0` means "not
/// recorded" here and never counts as an intake.
enum NutrientDetailSeries {
    /// One day that carried data, ready for the chart and the history.
    struct Day: Identifiable, Equatable {
        /// The wire day key (`yyyy-MM-dd`), the row identity.
        let id: String
        /// Start of the day in the device calendar; the bar spans this day.
        let day: Date
        /// Middle of the day, where the scrub rule meets the bar's centre.
        let midday: Date
        let amount: Double
    }

    /// Min, mean, max and median over the days with data.
    struct Stats: Equatable {
        let min: Double
        let mean: Double
        let max: Double
        let median: Double
    }

    /// The days with data, newest first: the history list. Empty days are
    /// left out instead of reading as "0 µg".
    static func history(_ days: [NutrientDayPointDTO], calendar: Calendar = .current) -> [Day] {
        Array(chartDays(days, calendar: calendar).reversed())
    }

    /// The days with data, oldest first: the bars.
    static func chartDays(_ days: [NutrientDayPointDTO], calendar: Calendar = .current) -> [Day] {
        days
            .filter { $0.amount > 0 }
            .compactMap { point -> Day? in
                guard let start = date(fromDayKey: point.day, calendar: calendar) else { return nil }
                let midday = calendar.date(byAdding: .hour, value: 12, to: start) ?? start
                return Day(id: point.day, day: start, midday: midday, amount: point.amount)
            }
            .sorted { $0.day < $1.day }
    }

    /// `nil` when no day of the window carried data.
    static func stats(_ days: [NutrientDayPointDTO]) -> Stats? {
        let amounts = days.map(\.amount).filter { $0 > 0 }.sorted()
        guard let first = amounts.first, let last = amounts.last else { return nil }
        let mean = amounts.reduce(0, +) / Double(amounts.count)
        let middle = amounts.count / 2
        let median = amounts.count.isMultiple(of: 2)
            ? (amounts[middle - 1] + amounts[middle]) / 2
            : amounts[middle]
        return Stats(min: first, mean: mean, max: last, median: median)
    }

    /// A wire day key read in the device calendar, so the 3rd stays the 3rd
    /// in every time zone. `nil` for a key that is not `yyyy-MM-dd`.
    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The same precision as ``NutrientDisplay/formatted(amount:wireUnit:locale:)``:
    /// small fractional amounts keep two decimals, everything else none.
    static func fractionDigits(for amount: Double) -> ClosedRange<Int> {
        amount < 10 && amount != amount.rounded() ? 0 ... 2 : 0 ... 0
    }
}
