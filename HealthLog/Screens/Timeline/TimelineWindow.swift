import Foundation
import SwiftUI

/// The days the timeline shows, both ends inclusive, as day numbers.
struct TimelineWindow: Equatable, Sendable {
    let from: Int
    let to: Int

    /// Days on the axis, at least one.
    var span: Int {
        max(1, to - from + 1)
    }

    /// Where on the axis a moment lies, 0 at the start of `from` and 1 at the
    /// end of `to`. A day `d` starts at `fraction(d)` and its middle is at
    /// `fraction(d + 0.5)`.
    func fraction(_ day: Double) -> Double {
        (day - Double(from)) / Double(span)
    }

    /// The day under a fraction of the axis, clamped into the window.
    func day(atFraction fraction: Double) -> Int {
        let raw = Int((Double(from) + fraction * Double(span)).rounded(.down))
        return min(max(raw, from), to)
    }

    func contains(_ day: Int) -> Bool {
        (from ... to).contains(day)
    }

    /// The first day of every month inside the window, for the month grid.
    var monthStarts: [Int] {
        var out: [Int] = []
        var month = TimelineDay.monthStart(from)
        if month < from { month = TimelineDay.bucketAfter(month, .month) }
        while month <= to {
            out.append(month)
            month = TimelineDay.bucketAfter(month, .month)
        }
        return out
    }

    /// The first day of every year inside the window.
    var yearStarts: [Int] {
        monthStarts.filter { TimelineDay.components($0).month == 1 }
    }
}

/// The quick choices of the floating period bar: a week, a month, three
/// months, six months, a year, everything. Between them the axis zooms
/// freely with two fingers; a window that matches none of them is
/// `.custom`, and the bar then marks no segment.
enum TimelinePeriod: String, CaseIterable, Identifiable, Sendable, HLRangeOption {
    case week
    case month
    case quarter
    case halfYear
    case year
    case all
    /// A window the person zoomed or moved to. Not a segment of the bar.
    case custom

    /// The segments of the bar, in order; `.custom` is none of them.
    static var allCases: [TimelinePeriod] {
        [.week, .month, .quarter, .halfYear, .year, .all]
    }

    var id: String {
        rawValue
    }

    /// The page opens on three months, like the web.
    static let standard: TimelinePeriod = .quarter

    var label: String {
        switch self {
        case .week: String(localized: "timeline.period.week.short")
        case .month: String(localized: "timeline.period.month.short")
        case .quarter: String(localized: "timeline.period.quarter.short")
        case .halfYear: String(localized: "timeline.period.halfYear.short")
        case .year: String(localized: "timeline.period.year.short")
        case .all, .custom: String(localized: "timeline.period.all.short")
        }
    }

    var rangeAccessibilityLabel: String {
        switch self {
        case .week: String(localized: "timeline.period.week")
        case .month: String(localized: "timeline.period.month")
        case .quarter: String(localized: "timeline.period.quarter")
        case .halfYear: String(localized: "timeline.period.halfYear")
        case .year: String(localized: "timeline.period.year")
        case .all: String(localized: "timeline.period.all")
        case .custom: String(localized: "timeline.period.custom")
        }
    }

    /// Days on the axis for the fixed spans; `nil` for everything and a custom window.
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 91
        case .halfYear: 182
        case .year: 365
        case .all, .custom: nil
        }
    }

    /// The window of a quick choice: its span up to today and a little room
    /// after it, a twelfth of the span, so today never stands on the edge.
    /// Everything runs from the record's first day.
    func window(today: Int, dataFrom: Int?) -> TimelineWindow {
        guard let days else {
            let first = min(dataFrom ?? today - 364, today - 6)
            let span = today - first + 1
            return TimelineWindow(from: first, to: today + max(1, span / 30))
        }
        let lead = max(1, days / 12)
        return TimelineWindow(from: today + lead - days + 1, to: today + lead)
    }

    /// What one request names: the zoom and, for a range, its ends.
    struct Request: Equatable, Sendable {
        let zoom: TimelineZoom
        var from: String?
        var to: String?
    }

    /// The request behind a window: everything as the server's own zoom,
    /// any other window as a range up to today at most. The server picks the
    /// bucket from the range's length, so a week comes in days and a year in
    /// months.
    static func request(for window: TimelineWindow, period: TimelinePeriod, today: Int) -> Request {
        if period == .all { return Request(zoom: .all) }
        let to = min(window.to, today)
        let from = min(window.from, to)
        return Request(zoom: .range, from: TimelineDay.key(from), to: TimelineDay.key(to))
    }

    /// A young record's three months start at its first entry, at least four
    /// weeks before today, so a few days of data neither hide in a sliver nor
    /// stretch thin (`resolveDefaultWindow` on the web).
    static func youngRecordWindow(_ window: TimelineWindow, dataFrom: Int?, today: Int) -> TimelineWindow {
        guard let dataFrom, dataFrom > window.from else { return window }
        let start = min(dataFrom, today - 27)
        return start > window.from ? TimelineWindow(from: start, to: window.to) : window
    }
}

// MARK: - Zoom and pan

extension TimelineWindow {
    /// The shortest window the axis zooms to: a week.
    static let minimumSpan = 7
    /// The longest a range can be on the server: fifteen years.
    static let maximumSpan = 15 * 365

    /// The window `scale` times closer (above 1) or farther (below 1),
    /// holding the day under `anchor` (0 at the leading edge, 1 at the
    /// trailing one) where it is, between a week and `maximumDays`, and
    /// never later than `latestEnd`.
    func zoomed(by scale: Double, anchor: Double, maximumDays: Int, latestEnd: Int) -> TimelineWindow {
        guard scale.isFinite, scale > 0 else { return self }
        let ceiling = max(Self.minimumSpan, min(maximumDays, Self.maximumSpan))
        let newSpan = min(max(Int((Double(span) / scale).rounded()), Self.minimumSpan), ceiling)
        let point = min(max(anchor, 0), 1)
        let anchorDay = Double(from) + point * Double(span)
        let newFrom = Int((anchorDay - point * Double(newSpan)).rounded())
        return TimelineWindow(from: newFrom, to: newFrom + newSpan - 1).clamped(latestEnd: latestEnd)
    }

    /// The window moved by `days` (later for a positive number), never later than `latestEnd`.
    func panned(by days: Int, latestEnd: Int) -> TimelineWindow {
        TimelineWindow(from: from + days, to: to + days).clamped(latestEnd: latestEnd)
    }

    private func clamped(latestEnd: Int) -> TimelineWindow {
        guard to > latestEnd else { return self }
        let shift = to - latestEnd
        return TimelineWindow(from: from - shift, to: latestEnd)
    }
}

/// The marks on the time axis for the window on screen: days, weeks,
/// months, quarters or years, the finest that still leaves each label its
/// room. A pure function of the window and the width, so zooming only ever
/// moves between these steps.
enum TimelineAxisStep: Equatable, Sendable, CaseIterable {
    case day
    case week
    case month
    case quarter
    case year

    /// Days one step covers on average.
    var averageDays: Double {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30.44
        case .quarter: 91.31
        case .year: 365.25
        }
    }

    /// Room a label needs: a day or a week names day and month, wider than a month alone.
    var minimumGap: CGFloat {
        switch self {
        case .day, .week: 58
        case .month, .quarter: 46
        case .year: 40
        }
    }

    /// The finest step whose marks stand far enough apart at `width`.
    static func step(window: TimelineWindow, width: CGFloat) -> TimelineAxisStep {
        guard width > 0 else { return .year }
        let pointsPerDay = width / CGFloat(window.span)
        return allCases.first { CGFloat($0.averageDays) * pointsPerDay >= $0.minimumGap } ?? .year
    }

    /// The first day of every step inside the window.
    func starts(in window: TimelineWindow) -> [Int] {
        var out: [Int] = []
        var day = first(onOrAfter: window.from)
        while day <= window.to {
            out.append(day)
            day = next(after: day)
        }
        return out
    }

    private func first(onOrAfter day: Int) -> Int {
        let start: Int = switch self {
        case .day: day
        case .week: TimelineDay.bucketStart(day, .week)
        case .month: TimelineDay.bucketStart(day, .month)
        case .quarter: TimelineDay.bucketStart(day, .quarter)
        case .year: TimelineDay.number(year: TimelineDay.components(day).year, month: 1, day: 1)
        }
        return start < day ? next(after: start) : start
    }

    private func next(after day: Int) -> Int {
        switch self {
        case .day: day + 1
        case .week: day + 7
        case .month: TimelineDay.bucketAfter(day, .month)
        case .quarter: TimelineDay.bucketAfter(day, .quarter)
        case .year: TimelineDay.number(year: TimelineDay.components(day).year + 1, month: 1, day: 1)
        }
    }
}

/// How the timeline lays itself out at the width it measured itself.
enum TimelineLayoutStyle: Equatable, Sendable {
    /// Names above each track, the plot edge to edge (iPhone upright,
    /// narrow windows).
    case stacked
    /// The full board: a column of names on the left, every track at one
    /// glance (iPad, the open Duo, wide windows).
    case board

    /// The board needs room for its name column and a plot that still shows
    /// a quarter in weeks: from 600 pt on.
    static let boardMinimumWidth: CGFloat = 600

    /// From the first accessibility text size on, every name stands above
    /// its row: a column of names that large would leave no room for the plot.
    static func style(width: CGFloat, typeSize: DynamicTypeSize = .large) -> TimelineLayoutStyle {
        width >= boardMinimumWidth && !typeSize.isAccessibilitySize ? .board : .stacked
    }

    /// The width of the name column on the board, a quarter of the width
    /// between 180 and 240 pt.
    static func labelColumnWidth(width: CGFloat) -> CGFloat {
        min(240, max(180, width * 0.22))
    }
}
