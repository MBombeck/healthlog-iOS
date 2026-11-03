import Charts
import SwiftUI

/// **1.4 B4 — one rule for every date x-axis in the app.**
///
/// Each chart used to pick its own format (`day().month()`, the Charts
/// default, a three-day stride) and let Swift Charts place the ticks. A tick
/// close to the plot's trailing edge then had no room for its centred label,
/// which Charts cut to "1…" or "19.…".
///
/// The rule: the app places the ticks itself. A calendar-aligned step (minutes,
/// hours, days, weeks, months, years) gives at most four labels, and no tick sits in
/// the outer eighth of the span on either side, so every centred label fits.
/// The label format follows the step: the time of day for minute and hour steps, day and
/// month for day and week steps, the month for month steps (with the year once
/// a step is half a year or more), the year for year steps. Hairline grid lines
/// in the chart grid tokens.
enum ChartDateAxis {
    /// One step between two ticks.
    struct Step: Equatable {
        let component: Calendar.Component
        let value: Int

        /// The step's rough length, to pick one for a span.
        var approximateSeconds: TimeInterval {
            let unit: TimeInterval = switch component {
            case .minute: 60
            case .hour: 3600
            case .day: 86400
            case .weekOfYear: 7 * 86400
            case .month: 30.44 * 86400
            default: 365.25 * 86400
            }
            return unit * Double(value)
        }

        var format: Date.FormatStyle {
            switch component {
            case .minute, .hour: return .dateTime.hour().minute()
            case .day, .weekOfYear: return .dateTime.day().month(.abbreviated)
            case .month:
                let month = Date.FormatStyle.dateTime.month(.abbreviated)
                return value >= 6 ? month.year(.twoDigits) : month
            default: return .dateTime.year()
            }
        }
    }

    /// The steps the axis may take, shortest first.
    static let steps: [Step] = [
        Step(component: .minute, value: 5), Step(component: .minute, value: 10), Step(component: .minute, value: 15),
        Step(component: .minute, value: 30), Step(component: .hour, value: 1), Step(component: .hour, value: 2), Step(
            component: .hour,
            value: 3
        ),
        Step(component: .hour, value: 6), Step(component: .hour, value: 12),
        Step(component: .day, value: 1), Step(component: .day, value: 2),
        Step(component: .weekOfYear, value: 1), Step(component: .weekOfYear, value: 2),
        Step(component: .month, value: 1), Step(component: .month, value: 2), Step(component: .month, value: 3),
        Step(component: .month, value: 6),
        Step(component: .year, value: 1), Step(component: .year, value: 2), Step(component: .year, value: 5),
        Step(component: .year, value: 10)
    ]

    /// At most this many steps fit the span, so at most four labels.
    static let maximumSteps = 4.5

    /// No tick in this share of the span at either edge.
    static let edgeMargin = 0.125

    /// The shortest step that keeps the labels to about four.
    static func step(forSpan span: TimeInterval) -> Step {
        steps.first { span / $0.approximateSeconds <= maximumSteps } ?? steps[steps.count - 1]
    }

    /// The ticks for a chart showing `first ... last`: on calendar boundaries
    /// of the step, none in the outer eighth of the span.
    static func ticks(from first: Date, to last: Date, calendar: Calendar = .current) -> [Date] {
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return [] }
        let step = step(forSpan: span)
        let lower = first.addingTimeInterval(span * edgeMargin)
        let upper = last.addingTimeInterval(-span * edgeMargin)
        var tick = alignedStart(onOrBefore: first, step: step, calendar: calendar)
        var ticks: [Date] = []
        // Bounded: the span holds at most `maximumSteps` steps plus the lead-in.
        for _ in 0 ..< 32 {
            if tick > upper { break }
            if tick >= lower { ticks.append(tick) }
            guard let next = calendar.date(byAdding: step.component, value: step.value, to: tick) else { break }
            tick = next
        }
        return ticks
    }

    /// The calendar boundary of `step` on or before `date`: the minute or hour
    /// that is a multiple of the step, the start of the day, week, month or year.
    static func alignedStart(onOrBefore date: Date, step: Step, calendar: Calendar) -> Date {
        switch step.component {
        case .minute:
            let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
            let minute = calendar.component(.minute, from: minuteStart)
            return calendar.date(byAdding: .minute, value: -(minute % step.value), to: minuteStart) ?? minuteStart
        case .hour:
            let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            let hour = calendar.component(.hour, from: hourStart)
            return calendar.date(byAdding: .hour, value: -(hour % step.value), to: hourStart) ?? hourStart
        case .day:
            return calendar.startOfDay(for: date)
        case .weekOfYear:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
            let month = calendar.component(.month, from: monthStart) - 1
            return calendar.date(byAdding: .month, value: -(month % step.value), to: monthStart) ?? monthStart
        default:
            let yearStart = calendar.dateInterval(of: .year, for: date)?.start ?? date
            let year = calendar.component(.year, from: yearStart)
            return calendar.date(byAdding: .year, value: -(year % step.value), to: yearStart) ?? yearStart
        }
    }

    /// Where an edge label sits against its tick on a category axis that
    /// labels only its first and last column: the first starts at its tick,
    /// the last ends at it, so neither runs out of the plot.
    static func labelAnchor(index: Int, count: Int) -> UnitPoint {
        guard count > 1 else { return .top }
        if index == 0 { return .topLeading }
        return index == count - 1 ? .topTrailing : .top
    }

    /// The x-axis for a chart plotting `dates`.
    static func marks(for dates: [Date]) -> some AxisContent {
        let first = dates.min() ?? .distantPast
        let last = dates.max() ?? .distantPast
        let format = step(forSpan: last.timeIntervalSince(first)).format
        return AxisMarks(values: ticks(from: first, to: last)) { value in
            AxisGridLine()
                .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
            if let date = value.as(Date.self) {
                // 1.4 B4-z — centred on its tick, as the rule above assumes.
                // Swift Charts starts a date label at its tick, so the last
                // one ran past the plot's edge ("Oct…" for Oct 18 in English,
                // where weeks start on Sunday and that tick sits later).
                AxisValueLabel(anchor: .top) {
                    Text(date, format: format)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }
}
