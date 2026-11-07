import Foundation

/// **1.5 LAB-LINES, from COACH-R point 5** — the usual-range sentence at the
/// top of the chart card, worded from `coach-read` line one.
///
/// It appears only when the server says whether the latest reading is from
/// today (`latestIsToday`, v1.41). Then a reading from an earlier day is
/// named by its date instead of being called today's; a glucose day still in
/// progress says that its range is the one for this time of day. Without the
/// field, without a baseline (still learning) or on any failure there is no
/// line: the card looks as it did in 1.4. Values are the server's, only
/// converted into the account's unit.
enum ChartCoachReadLine {
    static func text(
        _ strip: CoachReadStrip?,
        kind: MetricKind,
        units: UnitPreferences,
        calendar: Calendar = .current
    ) -> String? {
        guard let baseline = strip?.baseline, let isToday = baseline.latestIsToday else { return nil }
        func number(_ value: Double) -> String {
            MetricValueFormatter.formatScalar(value, kind: kind, units: units)
        }
        let low = number(baseline.low)
        let high = number(baseline.high)
        let value = number(baseline.latest)
        let unit = MetricValueFormatter.unitSuffix(for: kind, units: units)
        let steady = low == high
        if baseline.isSameHours {
            return sameHours(baseline.placement, low: low, high: high, unit: unit, value: value)
        }
        if !isToday {
            guard let date = baseline.latestDate.flatMap({ dayText($0, calendar: calendar) }) else { return nil }
            return steady
                ? steadyLatest(baseline.placement, low: low, unit: unit, date: date, value: value)
                : latest(baseline.placement, low: low, high: high, unit: unit, date: date, value: value)
        }
        return steady
            ? steadyToday(baseline.placement, low: low, unit: unit, value: value)
            : today(baseline.placement, low: low, high: high, unit: unit, value: value)
    }

    /// "3. November" for a `YYYY-MM-DD` day, read as a calendar day (no zone shift).
    static func dayText(_ dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = TimelineRepository.date(fromDayKey: dayKey, calendar: calendar) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).locale(AppLanguage.current.formattingLocale))
    }

    private typealias Placement = CoachReadStrip.Baseline.Placement

    private static func today(_ placement: Placement, low: String, high: String, unit: String, value: String) -> String {
        switch placement {
        case .within: String(localized: "insights.coachRead.today.within \(low) \(high) \(unit) \(value)")
        case .above: String(localized: "insights.coachRead.today.above \(low) \(high) \(unit) \(value)")
        case .below: String(localized: "insights.coachRead.today.below \(low) \(high) \(unit) \(value)")
        }
    }

    private static func steadyToday(_ placement: Placement, low: String, unit: String, value: String) -> String {
        switch placement {
        case .within: String(localized: "insights.coachRead.steady.within \(low) \(unit) \(value)")
        case .above: String(localized: "insights.coachRead.steady.above \(low) \(unit) \(value)")
        case .below: String(localized: "insights.coachRead.steady.below \(low) \(unit) \(value)")
        }
    }

    private static func latest(
        _ placement: Placement,
        low: String,
        high: String,
        unit: String,
        date: String,
        value: String
    ) -> String {
        switch placement {
        case .within: String(localized: "insights.coachRead.latest.within \(low) \(high) \(unit) \(date) \(value)")
        case .above: String(localized: "insights.coachRead.latest.above \(low) \(high) \(unit) \(date) \(value)")
        case .below: String(localized: "insights.coachRead.latest.below \(low) \(high) \(unit) \(date) \(value)")
        }
    }

    private static func steadyLatest(_ placement: Placement, low: String, unit: String, date: String, value: String) -> String {
        switch placement {
        case .within: String(localized: "insights.coachRead.steadyLatest.within \(low) \(unit) \(date) \(value)")
        case .above: String(localized: "insights.coachRead.steadyLatest.above \(low) \(unit) \(date) \(value)")
        case .below: String(localized: "insights.coachRead.steadyLatest.below \(low) \(unit) \(date) \(value)")
        }
    }

    private static func sameHours(_ placement: Placement, low: String, high: String, unit: String, value: String) -> String {
        switch placement {
        case .within: String(localized: "insights.coachRead.sameHours.within \(low) \(high) \(unit) \(value)")
        case .above: String(localized: "insights.coachRead.sameHours.above \(low) \(high) \(unit) \(value)")
        case .below: String(localized: "insights.coachRead.sameHours.below \(low) \(high) \(unit) \(value)")
        }
    }
}
