import Foundation

/// One bar on a lane: a stretch of days, or a gap inside one (a pause).
struct TimelineBar: Equatable, Identifiable, Sendable {
    let id: String
    /// First day number.
    let start: Int
    /// The day after the last one: bars end where the next day starts.
    let endExclusive: Int
    /// Still running: the bar ends at today with an arrow.
    let open: Bool
    /// The text on the bar; `nil` for a piece that repeats its neighbour.
    let label: String?
    /// A pause lies over its stretch as a gap.
    let isPause: Bool
    /// The bar begins with a change (a new dose): a small cut marks it.
    let beginsWithChange: Bool
}

/// A single day on a lane (a visit, a vaccination, a one-time medication).
struct TimelineMark: Equatable, Identifiable, Sendable {
    let id: String
    let day: Int
    let label: String?
}

/// One row of a lane. A medication has one row of its own.
struct TimelineLaneRow: Equatable, Identifiable, Sendable {
    let id: String
    /// The medication's name for a medication row; `nil` on the other lanes.
    let title: String?
    let bars: [TimelineBar]
    let marks: [TimelineMark]
}

/// A lane as the board draws it: its rows, top to bottom.
struct TimelineLaneTrack: Equatable, Identifiable, Sendable {
    let key: TimelineLaneKey
    let rows: [TimelineLaneRow]

    var id: TimelineLaneKey {
        key
    }

    /// The board shows lanes in the server's order.
    static let order: [TimelineLaneKey] = TimelineLaneKey.allCases

    /// The lanes worth a row, in order: present in the answer, not hidden by
    /// the person, with something inside the window.
    static func tracks(
        read: TimelineRead,
        window: TimelineWindow,
        today: Int,
        hidden: Set<TimelineLaneKey>,
        words: (TimelineItem) -> String
    ) -> [TimelineLaneTrack] {
        order.compactMap { key in
            guard !hidden.contains(key) else { return nil }
            let items = read.items(of: key)
            guard !items.isEmpty else { return nil }
            let rows = key == .medications
                ? medicationRows(items, window: window, today: today)
                : packedRows(items, key: key, window: window, today: today, words: words)
            return rows.isEmpty ? nil : TimelineLaneTrack(key: key, rows: rows)
        }
    }

    // MARK: - Medications

    /// One row per medication with something inside the window: its
    /// stretches cut at every dose change, pauses as gaps, one-time intakes
    /// and stray dose changes as marks.
    static func medicationRows(_ items: [TimelineItem], window: TimelineWindow, today: Int) -> [TimelineLaneRow] {
        TimelineMedicationGroup.groups(items).compactMap { group in
            var bars: [TimelineBar] = []
            // The first piece on screen carries the name, the later ones only
            // their new dose, so a medication is named even when its start
            // lies before the window.
            var named = false
            for period in group.periods {
                let segments = group.segments(of: period)
                for (index, segment) in segments.enumerated() {
                    let end = (segment.end ?? today) + 1
                    guard segment.start <= window.to, end > window.from else { continue }
                    let label = named ? segment.dose : [group.label, segment.dose].compactMap { $0 }.joined(separator: " ")
                    named = true
                    bars.append(TimelineBar(
                        id: "\(period.id)#\(index)",
                        start: segment.start,
                        endExclusive: max(end, segment.start + 1),
                        open: segment.end == nil,
                        label: label,
                        isPause: false,
                        beginsWithChange: index > 0
                    ))
                }
            }
            for pause in group.pauses {
                guard let bar = bar(pause, today: today, label: nil, isPause: true), overlaps(bar, window) else { continue }
                bars.append(bar)
            }
            let marks = (group.points + group.strayDoses).compactMap { item -> TimelineMark? in
                guard let day = TimelineDay.number(item.start), window.contains(day) else { return nil }
                let text = item.kind == .doseChange ? item.sub : [group.label, item.sub].compactMap { $0 }.joined(separator: " ")
                return TimelineMark(id: item.id, day: day, label: text)
            }
            guard bars.contains(where: { !$0.isPause }) || !marks.isEmpty else { return nil }
            return TimelineLaneRow(id: group.key, title: group.label, bars: bars, marks: marks)
        }
    }

    // MARK: - Other lanes

    /// Spans packed into the first row whose last bar ended before them,
    /// points on one row above them (the web's `layoutLane`).
    static func packedRows(
        _ items: [TimelineItem],
        key: TimelineLaneKey,
        window: TimelineWindow,
        today: Int,
        words: (TimelineItem) -> String
    ) -> [TimelineLaneRow] {
        var marks: [TimelineMark] = []
        var rows: [[TimelineBar]] = []
        let sorted = items.sorted { $0.start < $1.start }
        for item in sorted {
            if item.isSpan {
                guard let bar = bar(item, today: today, label: words(item), isPause: false), overlaps(bar, window) else {
                    continue
                }
                if let free = rows.firstIndex(where: { ($0.last?.endExclusive ?? .min) < bar.start }) {
                    rows[free].append(bar)
                } else {
                    rows.append([bar])
                }
            } else if let day = TimelineDay.number(item.start), window.contains(day) {
                marks.append(TimelineMark(id: item.id, day: day, label: words(item)))
            }
        }
        var out: [TimelineLaneRow] = []
        if !marks.isEmpty {
            out.append(TimelineLaneRow(id: "\(key.rawValue)-points", title: nil, bars: [], marks: marks))
        }
        for (index, bars) in rows.enumerated() {
            out.append(TimelineLaneRow(id: "\(key.rawValue)-\(index)", title: nil, bars: bars, marks: []))
        }
        return out
    }

    private static func bar(_ item: TimelineItem, today: Int, label: String?, isPause: Bool) -> TimelineBar? {
        guard let start = TimelineDay.number(item.start) else { return nil }
        let last = item.open ? today : (item.end.flatMap(TimelineDay.number) ?? start)
        return TimelineBar(
            id: item.id,
            start: start,
            endExclusive: max(last, start) + 1,
            open: item.open,
            label: label,
            isPause: isPause,
            beginsWithChange: false
        )
    }

    private static func overlaps(_ bar: TimelineBar, _ window: TimelineWindow) -> Bool {
        bar.start <= window.to && bar.endExclusive > window.from
    }
}
