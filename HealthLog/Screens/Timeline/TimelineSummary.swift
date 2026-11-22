import Foundation

/// The cross-section under the board for one chosen day: the bucket that
/// holds it ("Woche vom 16. November 2026"), every entry that touches the
/// bucket, the mean of every value line in it and the lab readings in it
/// (the web's `SelectionBar`).
struct TimelineSummary: Equatable, Sendable {
    /// One entry of a lane in the period.
    struct Entry: Equatable, Identifiable, Sendable {
        let lane: TimelineLaneKey
        let item: TimelineItem

        var id: String {
            "\(lane.rawValue)-\(item.id)"
        }
    }

    /// One value line in the period: its mean, or `nil` when it has none.
    struct Value: Equatable, Identifiable, Sendable {
        let key: String
        let mean: Double?
        let count: Int

        var id: String {
            key
        }
    }

    /// One lab reading in the period.
    struct Reading: Equatable, Identifiable, Sendable {
        let key: String
        let point: TimelineLabPoint

        var id: String {
            point.id
        }
    }

    let bucket: TimelineBucket
    /// First and last day of the period, inclusive.
    let from: Int
    let to: Int
    let entries: [Entry]
    let values: [Value]
    let readings: [Reading]

    /// Nothing in the period at all.
    var isEmpty: Bool {
        entries.isEmpty && readings.isEmpty && values.allSatisfy { $0.mean == nil }
    }

    static func make(read: TimelineRead, day: Int, today: Int, hidden: Set<TimelineLaneKey>) -> TimelineSummary {
        let from = TimelineDay.bucketStart(day, read.bucket)
        let to = TimelineDay.bucketAfter(from, read.bucket) - 1
        let fromKey = TimelineDay.key(from)
        let toKey = TimelineDay.key(to)
        let todayKey = TimelineDay.key(today)
        let lanes = read.lanes.filter { !hidden.contains($0.key) }
        let means = read.series.map { mean(of: $0.key, $0.points, from: fromKey) }
            + read.symptomSeries.map { mean(of: $0.key, $0.points, from: fromKey) }
        let readings = read.labSeries.flatMap { series in
            series.points.filter { $0.date >= fromKey && $0.date <= toKey }.map { Reading(key: series.key, point: $0) }
        }
        return TimelineSummary(
            bucket: read.bucket,
            from: from,
            to: to,
            entries: entries(lanes: lanes, from: fromKey, to: toKey, today: todayKey),
            values: means,
            readings: readings
        )
    }

    private static func mean(of key: String, _ points: [TimelineValuePoint], from: String) -> Value {
        let point = points.first { $0.t == from }
        return Value(key: key, mean: point?.mean, count: point?.count ?? 0)
    }

    /// The entries that touch `[from, to]` in lane order. A span open since
    /// before the period is its backdrop and left out; a medication is one
    /// entry however many of its items touch the period; documents stay out.
    static func entries(lanes: [TimelineLane], from: String, to: String, today: String) -> [Entry] {
        var out: [Entry] = []
        for key in TimelineLaneTrack.order where key != .documents {
            guard let lane = lanes.first(where: { $0.key == key }) else { continue }
            if key == .medications {
                for group in TimelineMedicationGroup.groups(lane.items) {
                    if let item = group.periodEntry(from: from, to: to, today: today) {
                        out.append(Entry(lane: key, item: item))
                    }
                }
                continue
            }
            for item in lane.items {
                let end = item.open ? today : (item.end ?? item.start)
                guard item.start <= to, end >= from else { continue }
                if item.open, item.start < from { continue }
                out.append(Entry(lane: key, item: item))
            }
        }
        return out
    }

    /// The day to show before anyone picks one: the newest day inside the
    /// window, not after today, that the summary has something for.
    static func latestDataDay(read: TimelineRead, window: TimelineWindow, today: Int) -> Int? {
        let last = min(window.to, today)
        var best: Int?
        func consider(_ key: String?) {
            guard let key, let day = TimelineDay.number(key), day >= window.from, day <= last else { return }
            best = max(best ?? day, day)
        }
        for lane in read.lanes where lane.key != .documents {
            for item in lane.items {
                guard let start = TimelineDay.number(item.start), start <= last else { continue }
                if item.open {
                    consider(item.start)
                } else if let end = TimelineDay.number(item.end ?? item.start) {
                    consider(TimelineDay.key(min(end, last)))
                }
            }
        }
        for series in read.series {
            series.points.forEach { consider($0.t) }
        }
        for series in read.symptomSeries {
            series.points.forEach { consider($0.t) }
        }
        for series in read.labSeries {
            series.points.forEach { consider($0.date) }
        }
        return best
    }
}
