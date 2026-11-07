import Foundation

/// **1.5 VISIT** — the stretch a doctor report offered for a booked visit
/// covers: `preparation.from` to `preparation.to`, exactly as the server
/// resolved them. Day keys on the record's calendar; the app reads them in the
/// device calendar, as every other day key (a window from the 3rd starts on
/// the 3rd in every zone).
///
/// The sharing surface takes it as a preset in place of a look-back of N days
/// (``UnifiedSharingStore/window``). Nothing here chooses a date: the only
/// arithmetic is the edge of a day and the stop at "now", because a report
/// cannot hold readings that have not been taken yet (the web stops the same
/// window at today).
public struct ReportWindow: Equatable, Hashable, Sendable {
    /// First day, `YYYY-MM-DD`.
    public let from: String
    /// Last day, `YYYY-MM-DD` (the visit's own day).
    public let to: String

    /// `nil` for a day key that is not a calendar day, or a window that ends
    /// before it starts.
    public init?(from: String, to: String) {
        guard let start = Self.dayNumber(from), let end = Self.dayNumber(to), start <= end else { return nil }
        self.from = from
        self.to = to
    }

    public init?(preparation: EncounterPreparation) {
        self.init(from: preparation.from, to: preparation.to)
    }

    /// The window as instants: from the start of `from` to the end of `to`
    /// (the start of the next day), stopped at `now`. `nil` when `from` lies
    /// after `now` or a day does not exist in `calendar`.
    public func interval(calendar: Calendar, now: Date) -> DateInterval? {
        guard let fromParts = Self.dayComponents(from), let toParts = Self.dayComponents(to),
              let start = calendar.date(from: fromParts),
              let lastDay = calendar.date(from: toParts),
              let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) else { return nil }
        let startOfFirst = calendar.startOfDay(for: start)
        let end = min(afterLast, now)
        guard end > startOfFirst else { return nil }
        return DateInterval(start: startOfFirst, end: end)
    }

    /// `range` of `POST /api/export/health-record`: `startDate` and `endDate`
    /// as instants with an offset. `nil` like ``interval(calendar:now:)``.
    public func exportRange(calendar: Calendar, now: Date) -> HealthRecordExportRequest.Range? {
        guard let interval = interval(calendar: calendar, now: now) else { return nil }
        return HealthRecordExportRequest.Range(
            startDate: Self.instant(interval.start),
            endDate: Self.instant(interval.end)
        )
    }

    /// `YYYY-MM-DD` to year, month and day; `nil` for anything else.
    static func dayComponents(_ key: String) -> DateComponents? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        let probe = DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day)
        guard probe.isValidDate else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `20261105` for `2026-11-05`, so two day keys compare as days.
    static func dayNumber(_ key: String) -> Int? {
        guard let parts = dayComponents(key), let year = parts.year, let month = parts.month,
              let day = parts.day else { return nil }
        return year * 10000 + month * 100 + day
    }

    /// An instant as the server's `date-time` with an offset (`Z`).
    static func instant(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
