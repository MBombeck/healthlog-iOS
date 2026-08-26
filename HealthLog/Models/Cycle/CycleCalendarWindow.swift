import Foundation

/// The `from`/`to`/`dayAnchor` triple for a calendar read. Default mirrors the
/// server window (−90 … +180 days). Computed off the user-tz calendar.
///
/// Lives in `Models/Cycle` (Foundation-only) rather than next to `CycleStore`
/// because `CycleRepository.purgeAll()` (server-parity v1.16) invalidates the
/// default-window SWR keys, and the Repositories folder also compiles into the
/// widgets extension, which excludes the Stores layer.
public struct CycleCalendarWindow: Sendable, Equatable {
    public let from: String
    public let to: String
    public let dayAnchor: String

    public init(from: String, to: String, dayAnchor: String) {
        self.from = from
        self.to = to
        self.dayAnchor = dayAnchor
    }

    public static var `default`: CycleCalendarWindow {
        let today = todayKey()
        return CycleCalendarWindow(
            from: shifted(today, days: -90),
            to: shifted(today, days: 180),
            dayAnchor: today
        )
    }

    /// `YYYY-MM-DD` for "today" in the device timezone.
    public static func todayKey(date: Date = .now) -> String {
        formatter.string(from: date)
    }

    private static func shifted(_ day: String, days: Int) -> String {
        guard let base = formatter.date(from: day),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: base) else { return day }
        return formatter.string(from: moved)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
