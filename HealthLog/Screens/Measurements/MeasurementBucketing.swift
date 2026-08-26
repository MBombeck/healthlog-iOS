import Foundation

// v0.5.5.1 — extracted from `MeasurementListScreen.swift` so the screen
// stays under the 600-line SwiftLint `file_length` baseline once the
// v0.5.5.1 chip + search filter additions landed. Types + algorithms
// are unchanged (same module, same module-internal access); only the
// file boundary moves. `MeasurementBucketingTests` continues to import
// `@testable import HealthLog` and lock the contract.

/// Apple-Health-style section bucketing for the Verlauf list. Pure value-
/// type transform over `[Measurement]` — testable without spinning up the
/// screen.
enum MeasurementSection: Identifiable, Equatable {
    case day(date: Date, items: [Measurement])
    case weeklySummary(weekStart: Date, items: [Measurement])
    case monthlySummary(monthStart: Date, items: [Measurement])

    var id: String {
        switch self {
        case let .day(date, _):
            "day-\(date.timeIntervalSince1970)"
        case let .weeklySummary(start, _):
            "week-\(start.timeIntervalSince1970)"
        case let .monthlySummary(start, _):
            "month-\(start.timeIntervalSince1970)"
        }
    }
}

enum MeasurementBucketing {
    /// Boundary for collapsing a week into a summary row. >threshold triggers
    /// aggregation; ≤threshold renders per-day rows. Mirrors Apple Health's
    /// rollup-when-noisy behaviour.
    static let weeklyThreshold: Int = 5

    /// Boundary for collapsing a month into a summary row (only applies past
    /// the 90-day mark).
    static let monthlyThreshold: Int = 20

    /// Rule:
    /// - last 7 days (inclusive of today) → per-day raw rows
    /// - days 8 to 90 → weeklySummary if `>weeklyThreshold` items in that
    ///   ISO week, otherwise per-day raw rows
    /// - older than 90 days → monthlySummary if `>monthlyThreshold` items
    ///   in that month, otherwise per-day raw rows
    static func sections(
        for items: [Measurement],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [MeasurementSection] {
        let sorted = items.sorted { $0.recordedAt > $1.recordedAt }
        guard !sorted.isEmpty else { return [] }

        var recent: [Measurement] = []
        var midRange: [Measurement] = []
        var older: [Measurement] = []
        let recentCutoff = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)) ?? now
        let olderCutoff = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now)) ?? now
        for m in sorted {
            if m.recordedAt >= recentCutoff {
                recent.append(m)
            } else if m.recordedAt >= olderCutoff {
                midRange.append(m)
            } else {
                older.append(m)
            }
        }

        var result: [MeasurementSection] = []
        result.append(contentsOf: daySections(for: recent, calendar: calendar))
        result.append(contentsOf: weekRangeSections(for: midRange, calendar: calendar))
        result.append(contentsOf: monthRangeSections(for: older, calendar: calendar))
        return result
    }

    /// Per-day sections — one section per calendar day. Used for the
    /// most-recent 7-day window where users want raw resolution.
    static func daySections(for items: [Measurement], calendar: Calendar) -> [MeasurementSection] {
        let grouped = groupedSorted(items, by: { calendar.startOfDay(for: $0.recordedAt) })
        return grouped.map { day, items in
            .day(date: day, items: items)
        }
    }

    /// Per-week range — emits `weeklySummary` if count > `weeklyThreshold`,
    /// else per-day rows inside that week.
    static func weekRangeSections(for items: [Measurement], calendar: Calendar) -> [MeasurementSection] {
        let grouped = groupedSorted(items, by: { calendar.dateInterval(of: .weekOfYear, for: $0.recordedAt)?.start ?? $0.recordedAt })
        var result: [MeasurementSection] = []
        for (weekStart, weekItems) in grouped {
            if weekItems.count > weeklyThreshold {
                result.append(.weeklySummary(weekStart: weekStart, items: weekItems))
            } else {
                result.append(contentsOf: daySections(for: weekItems, calendar: calendar))
            }
        }
        return result
    }

    /// Per-month range — emits `monthlySummary` if count > `monthlyThreshold`,
    /// else falls back to weekly summaries (or day-rows) inside that month.
    static func monthRangeSections(for items: [Measurement], calendar: Calendar) -> [MeasurementSection] {
        let grouped = groupedSorted(items, by: { calendar.dateInterval(of: .month, for: $0.recordedAt)?.start ?? $0.recordedAt })
        var result: [MeasurementSection] = []
        for (monthStart, monthItems) in grouped {
            if monthItems.count > monthlyThreshold {
                result.append(.monthlySummary(monthStart: monthStart, items: monthItems))
            } else {
                result.append(contentsOf: weekRangeSections(for: monthItems, calendar: calendar))
            }
        }
        return result
    }

    /// Group + sort descending by bucket key, preserving the input's already-
    /// descending recordedAt order inside each bucket.
    private static func groupedSorted<Key: Hashable & Comparable>(
        _ items: [Measurement],
        by key: (Measurement) -> Key
    ) -> [(Key, [Measurement])] {
        var bucketOrder: [Key] = []
        var bucketed: [Key: [Measurement]] = [:]
        for m in items {
            let k = key(m)
            if bucketed[k] == nil {
                bucketed[k] = []
                bucketOrder.append(k)
            }
            bucketed[k]?.append(m)
        }
        // bucketOrder follows input order — items are pre-sorted descending,
        // so the bucket order is implicitly newest-first. Sort explicitly to
        // make the rule independent of input order.
        bucketOrder.sort(by: >)
        return bucketOrder.compactMap { k in
            guard let v = bucketed[k] else { return nil }
            return (k, v)
        }
    }

    // MARK: - Labels

    static func dayLabel(date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        // b215 — older buckets add the year when it isn't the current one so a
        // day header from a prior year ("Mo, 14. Juni") is never ambiguous.
        return HLDateFormat.appendingYearIfNeeded(
            date,
            base: .dateTime.weekday(.abbreviated).day().month(),
            relativeTo: now,
            calendar: calendar
        )
    }

    /// Header shown above a weeklySummary section — short calendar-week
    /// reference like "KW 19 · 13–19 Mai".
    static func weekHeader(start: Date, calendar: Calendar = .current) -> String {
        let weekOfYear = calendar.component(.weekOfYear, from: start)
        let endDate = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return "KW \(weekOfYear) · \(rangeLabel(start: start, end: endDate))"
    }

    /// Label inside the summary card — humane "Diese Woche" / explicit week.
    static func weekLabel(start: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: now), interval.start == start {
            return String(localized: "This week")
        }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           let interval = calendar.dateInterval(of: .weekOfYear, for: lastWeek), interval.start == start
        {
            return String(localized: "Last week")
        }
        let endDate = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return rangeLabel(start: start, end: endDate)
    }

    static func monthHeader(start: Date, calendar _: Calendar = .current) -> String {
        start.formatted(.dateTime.month(.wide).year())
    }

    static func monthLabel(start: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let interval = calendar.dateInterval(of: .month, for: now), interval.start == start {
            return String(localized: "This month")
        }
        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now),
           let interval = calendar.dateInterval(of: .month, for: lastMonth), interval.start == start
        {
            return String(localized: "Last month")
        }
        return start.formatted(.dateTime.month(.wide).year())
    }

    private static func rangeLabel(start: Date, end: Date) -> String {
        // "13–19 Mai" — month appears only once when both ends share a month.
        let calendar = Calendar.current
        let startDay = calendar.component(.day, from: start)
        let endDay = calendar.component(.day, from: end)
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let monthLabel = end.formatted(.dateTime.month(.abbreviated))
        if sameMonth {
            return "\(startDay)–\(endDay) \(monthLabel)"
        }
        let startMonthLabel = start.formatted(.dateTime.month(.abbreviated))
        return "\(startDay) \(startMonthLabel) – \(endDay) \(monthLabel)"
    }
}

/// Pure aggregate stats over a Measurement bucket. `secondary*` are populated
/// only when the bucket contains BP readings (diastolic). v0.5.5.1 — moved
/// here alongside `MeasurementBucketing` to keep the pure-data layer in one
/// place.
struct SummaryStats: Equatable {
    let count: Int
    let mean: Double
    let min: Double
    let max: Double
    let secondaryMean: Double?
    let secondaryMin: Double?
    let secondaryMax: Double?

    static func compute(items: [Measurement]) -> SummaryStats {
        let primaries = items.map(\.primaryValue)
        let secondaries: [Double] = items.compactMap { m in
            if case let .bloodPressure(_, d) = m.value { return d }
            return nil
        }
        let primaryMean = primaries.isEmpty ? 0 : primaries.reduce(0, +) / Double(primaries.count)
        let secondaryMean: Double? = secondaries.isEmpty ? nil : secondaries.reduce(0, +) / Double(secondaries.count)
        return SummaryStats(
            count: items.count,
            mean: primaryMean,
            min: primaries.min() ?? 0,
            max: primaries.max() ?? 0,
            secondaryMean: secondaryMean,
            secondaryMin: secondaries.min(),
            secondaryMax: secondaries.max()
        )
    }
}
