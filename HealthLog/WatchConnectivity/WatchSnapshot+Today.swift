import Foundation

public extension WatchSnapshot {
    /// Longest a snapshot may stand in for "today" on the wrist. Same value as
    /// the complications' `WatchComplicationStaleness.complianceMaxAge` and the
    /// phone widget's compliance rule.
    static let todayMaxAge: TimeInterval = 24 * 60 * 60

    /// `true` when this snapshot no longer describes today: minted on an
    /// earlier local day, or more than ``todayMaxAge`` ago. The watch then
    /// shows neither the counts nor actionable doses, because a tap would book
    /// a slot of a day that is over.
    func isStaleForToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if !calendar.isDate(generatedAt, inSameDayAs: now) { return true }
        return now.timeIntervalSince(generatedAt) > Self.todayMaxAge
    }

    /// The moments ahead at which ``isStaleForToday(now:calendar:)`` can flip:
    /// the next local midnight and the end of ``todayMaxAge``. A screen left
    /// open re-evaluates there instead of showing yesterday's doses after
    /// midnight.
    func todayBoundaries(after now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        let ageLimit = generatedAt.addingTimeInterval(Self.todayMaxAge)
        return [midnight, ageLimit].compactMap { $0 }.filter { $0 > now }.sorted()
    }
}
