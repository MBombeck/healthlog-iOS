import Foundation

/// The `from`/`to`/`dayAnchor` triple for a calendar read. Default mirrors the
/// server window (−90 … +180 days). Computed off the profile-zone calendar
/// (`ProfileDay`, #115 1.5).
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

    /// `YYYY-MM-DD` for "today" in the ACCOUNT zone (#115 1.5). The server
    /// keys the calendar's days in the profile zone; "today" from the device
    /// zone put the window's anchor (and the grid's today ring) on a day the
    /// account is not on, for anyone whose phone and account disagree.
    public static func todayKey(date: Date = .now, timeZone: TimeZone = ProfileDay.timeZone) -> String {
        ProfileDay.key(for: date, timeZone: timeZone)
    }

    private static func shifted(_ day: String, days: Int) -> String {
        ProfileDay.key(day, addingDays: days)
    }
}
