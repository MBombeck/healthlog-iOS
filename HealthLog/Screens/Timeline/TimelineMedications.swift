import Foundation

/// One medication, one row, read the way the web reads it
/// (`medication-rows.ts`).
///
/// The server sends a medication as several items that share its id as
/// `group`: its own span, its courses, its dose changes and its pauses. Drawn
/// item by item a course read as a second medication. Here they become one
/// thing again: the stretches it was taken are its courses (or its own span
/// without any), each dose change cuts the stretch it falls into, and a pause
/// is a gap in the same bar.
struct TimelineMedicationGroup: Equatable, Sendable {
    let key: String
    let label: String
    /// The stretches it was taken, oldest first.
    let periods: [TimelineItem]
    /// Taken once: a point, not a stretch.
    let points: [TimelineItem]
    let pauses: [TimelineItem]
    /// Dose changes, oldest first.
    let doses: [TimelineItem]
    let medication: TimelineItem?

    /// The medications lane's items, one group per medication, ordered by
    /// the first day anything of it happened.
    static func groups(_ items: [TimelineItem]) -> [TimelineMedicationGroup] {
        var order: [String] = []
        var byKey: [String: [TimelineItem]] = [:]
        for item in items {
            let key = item.group ?? item.id
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        let groups = order.compactMap { key -> TimelineMedicationGroup? in
            guard let list = byKey[key], let firstItem = list.first else { return nil }
            let medication = list.first { $0.kind == .medication }
            let courses = list.filter { $0.kind == .course }.sorted(by: Self.byStart)
            let stretches = courses + ownStretch(medication, courses: courses)
            return TimelineMedicationGroup(
                key: key,
                label: medication?.label ?? firstItem.label,
                periods: stretches.filter(\.isSpan).sorted(by: Self.byStart),
                points: stretches.filter { !$0.isSpan }.sorted(by: Self.byStart),
                pauses: list.filter { $0.kind == .pause }.sorted(by: Self.byStart),
                doses: list.filter { $0.kind == .doseChange }.sorted(by: Self.byStart),
                medication: medication
            )
        }
        return groups.sorted { $0.firstDay < $1.firstDay }
    }

    private var firstDay: String {
        (periods + points + pauses + doses).map(\.start).min() ?? ""
    }

    private static func byStart(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Bool {
        lhs.start < rhs.start
    }

    /// The medication's own span where its courses do not say when it was
    /// taken: all of it without a course, and the time since the last course
    /// ended while it is still taken and no course is open.
    private static func ownStretch(_ medication: TimelineItem?, courses: [TimelineItem]) -> [TimelineItem] {
        guard let medication else { return [] }
        if courses.isEmpty { return [medication] }
        guard medication.open, !courses.contains(where: \.open),
              let lastEnd = courses.map({ $0.end ?? $0.start }).max(),
              let lastDay = TimelineDay.number(lastEnd) else { return [] }
        let start = TimelineDay.key(lastDay + 1)
        if start <= medication.start { return [medication] }
        return [TimelineItem(
            id: "\(medication.id):since",
            kind: medication.kind,
            start: start,
            end: medication.end,
            open: medication.open,
            startKnown: medication.startKnown,
            label: medication.label,
            sub: medication.sub,
            group: medication.group
        )]
    }

    /// The dose in effect on `day`: the last dose change on or before it,
    /// the medication's own dose without any change, nothing before the first.
    func dose(on day: String) -> String? {
        guard !doses.isEmpty else { return medication?.sub }
        var dose: String?
        for change in doses {
            if change.start > day { break }
            dose = change.sub
        }
        return dose
    }

    /// One piece of a stretch: the days one dose was taken.
    struct DoseSegment: Equatable, Sendable {
        /// First day number.
        let start: Int
        /// Last day number, inclusive; `nil` while the stretch is open.
        let end: Int?
        let dose: String?
        /// Whether the piece begins with a dose change.
        let beginsWithChange: Bool
    }

    /// A stretch cut at every dose change that falls inside it.
    func segments(of period: TimelineItem) -> [DoseSegment] {
        guard let periodStart = TimelineDay.number(period.start) else { return [] }
        let end = period.open ? nil : TimelineDay.number(period.end ?? period.start)
        let cuts = doses.compactMap { change -> (Int, String?)? in
            guard let day = TimelineDay.number(change.start), day > periodStart,
                  end.map({ day <= $0 }) ?? true else { return nil }
            return (day, change.sub)
        }
        var out: [DoseSegment] = []
        var start = periodStart
        var current: String? = dose(on: period.start)
        var startsWithChange = doses.contains { $0.start == period.start }
        for (day, sub) in cuts {
            if day == start {
                current = sub
                continue
            }
            out.append(DoseSegment(start: start, end: day - 1, dose: current, beginsWithChange: startsWithChange))
            start = day
            current = sub
            startsWithChange = true
        }
        out.append(DoseSegment(start: start, end: end, dose: current, beginsWithChange: startsWithChange))
        return out
    }

    /// Dose changes outside every stretch: drawn as a mark of their own.
    var strayDoses: [TimelineItem] {
        doses.filter { change in
            !periods.contains { period in
                change.start >= period.start && (period.open || change.start <= (period.end ?? period.start))
            }
        }
    }

    /// This medication in the summary of `[from, to]`, or `nil` when nothing
    /// of it happens there. A pause names it paused, a dose change the new
    /// dose, otherwise the stretch that touches the period with the dose at
    /// its end. A stretch open since before the period is its backdrop and
    /// left out, as every other lane leaves it.
    func periodEntry(from: String, to: String, today: String) -> TimelineItem? {
        func touches(_ item: TimelineItem) -> Bool {
            let end = item.open ? today : (item.end ?? item.start)
            return item.start <= to && end >= from
        }
        if let pause = pauses.last(where: touches) {
            return TimelineItem(
                id: key, kind: .pause, start: pause.start, end: pause.end, open: pause.open,
                startKnown: pause.startKnown, label: label, sub: nil, group: key
            )
        }
        let stretches = (periods + points).filter(touches).sorted { $0.start < $1.start }
        if let change = doses.last(where: { $0.start >= from && $0.start <= to }) {
            let host = stretches.first { $0.start <= change.start && ($0.open || ($0.end ?? $0.start) >= change.start) }
            return TimelineItem(
                id: key, kind: .medication, start: change.start, end: host?.end, open: host?.open ?? false,
                label: label, sub: change.sub, group: key
            )
        }
        guard let last = stretches.last, !(last.open && last.start < from) else { return nil }
        let end = last.open ? today : (last.end ?? last.start)
        return TimelineItem(
            id: key, kind: .medication, start: last.start, end: last.end, open: last.open,
            startKnown: last.startKnown, label: label, sub: dose(on: end < to ? end : to), group: key
        )
    }
}
