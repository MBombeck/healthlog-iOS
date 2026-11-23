import Foundation

/// Where a value line comes from.
enum TimelineValueSource: Equatable, Sendable {
    /// A measurement type or the mood score: bucket means.
    case measurement
    /// A lab marker: every reading on its own day, never a mean.
    case lab
    /// A person-defined symptom: bucket means on the fixed scale 0 to 10.
    case symptom
}

/// The direction of the last step of a line.
enum TimelineTrend: Equatable, Sendable {
    case rising
    case falling
    case steady
    /// Fewer than two points: no direction to tell.
    case unknown
}

/// One point of a value line.
struct TimelinePlotPoint: Equatable, Identifiable, Sendable {
    /// The bucket's first day (a reading's day for a lab line).
    let id: String
    /// Where the point stands on the axis, in days (a bucket's middle).
    let day: Double
    let value: Double
    /// A mean from fewer than three readings: drawn hollow.
    let isThin: Bool
    /// A lab reading outside its reference range.
    let isOutOfRange: Bool
}

/// One value line as the board draws it.
struct TimelineValueTrack: Equatable, Identifiable, Sendable {
    let id: String
    let source: TimelineValueSource
    let unit: String?
    let points: [TimelinePlotPoint]
    /// Runs of neighbouring buckets, each drawn as one solid line.
    let runs: [[TimelinePlotPoint]]
    /// Short gaps, each a pair of real points joined by a dashed stroke.
    let bridges: [[TimelinePlotPoint]]
    /// The vertical extent the line is drawn in.
    let domain: ClosedRange<Double>
    /// The reference range of a lab line, either edge open.
    let band: TimelineLabBand?
    let trend: TimelineTrend

    /// The newest point inside the window.
    var latest: TimelinePlotPoint? {
        points.last
    }

    var isEmpty: Bool {
        points.isEmpty
    }

    /// A bucket mean from fewer readings than this is drawn hollow.
    static let thinCount = 3

    /// The most missing buckets a dashed bridge spans; beyond it the line
    /// stops and starts again (`MAX_BRIDGED_GAP` on the web): about six
    /// months, never more than a third of what the zoom shows.
    static func maxBridgedGap(_ bucket: TimelineBucket) -> Int {
        switch bucket {
        case .quarter: 1
        case .month: 2
        case .week: 4
        case .day: 3
        }
    }

    // MARK: - Building

    /// A measurement or symptom line: one point in the middle of every
    /// bucket that has a reading, solid where buckets follow each other,
    /// dashed over a short gap, broken over a long one. Nothing is invented
    /// between two real points.
    static func meanTrack(
        key: String,
        source: TimelineValueSource,
        unit: String?,
        points raw: [TimelineValuePoint],
        bucket: TimelineBucket,
        window: TimelineWindow
    ) -> TimelineValueTrack {
        // The server sends its buckets oldest first: skip to the first one
        // that can reach into the window (no bucket is longer than 92 days)
        // instead of walking years of points on every frame of a zoom.
        let firstCandidate = raw.partitioningIndex { ($0.day ?? .min) >= window.from - 92 }
        var inside: [(start: Int, point: TimelineValuePoint)] = []
        for point in raw[firstCandidate...] {
            guard let start = point.day else { continue }
            if start > window.to { break }
            guard point.mean.isFinite, TimelineDay.bucketAfter(start, bucket) > window.from else { continue }
            inside.append((start, point))
        }
        let points = inside.map { entry in
            let middle = (Double(entry.start) + Double(TimelineDay.bucketAfter(entry.start, bucket))) / 2
            let clamped = min(max(middle, Double(window.from)), Double(window.to + 1))
            return TimelinePlotPoint(
                id: entry.point.t, day: clamped, value: entry.point.mean,
                isThin: entry.point.count < thinCount, isOutOfRange: false
            )
        }
        var runs: [[TimelinePlotPoint]] = []
        var bridges: [[TimelinePlotPoint]] = []
        var current: [TimelinePlotPoint] = []
        for (index, point) in points.enumerated() {
            guard index > 0 else {
                current = [point]
                continue
            }
            let missing = TimelineDay.bucketIndex(inside[index].start, bucket)
                - TimelineDay.bucketIndex(inside[index - 1].start, bucket) - 1
            if missing == 0 {
                current.append(point)
                continue
            }
            if current.count > 1 { runs.append(current) }
            if missing <= maxBridgedGap(bucket) { bridges.append([points[index - 1], point]) }
            current = [point]
        }
        if current.count > 1 { runs.append(current) }
        let domain = source == .symptom ? 0.0 ... 10.0 : paddedDomain(points.map(\.value))
        return TimelineValueTrack(
            id: key, source: source, unit: unit, points: points, runs: runs, bridges: bridges,
            domain: domain, band: nil, trend: trend(points, domain: domain)
        )
    }

    /// A lab line: a point per reading on its day, joined in time order.
    /// The domain holds the points and the reference range together, so a
    /// reading outside the range reads as outside at a glance.
    static func labTrack(_ series: TimelineLabSeries, window: TimelineWindow) -> TimelineValueTrack {
        let points = series.points.compactMap { point -> TimelinePlotPoint? in
            guard let day = TimelineDay.number(point.date), window.contains(day), point.value.isFinite else { return nil }
            return TimelinePlotPoint(
                id: point.id, day: Double(day) + 0.5, value: point.value, isThin: false,
                isOutOfRange: point.rangeStatus == .above || point.rangeStatus == .below
            )
        }
        let band = series.band.flatMap { $0.isEmpty ? nil : $0 }
        let bounds = [band?.low, band?.high].compactMap { $0 }
        let domain = paddedDomain(points.map(\.value) + bounds)
        return TimelineValueTrack(
            id: series.key, source: .lab, unit: series.unit, points: points,
            runs: points.count > 1 ? [points] : [], bridges: [], domain: domain,
            band: band, trend: trend(points, domain: domain)
        )
    }

    /// The values with a margin above and below, so a line never sits on the
    /// edge of its row; a single value still gets a span to stand in.
    static func paddedDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        let pad = high > low ? max((high - low) * 0.12, abs(high) * 0.01) : max(abs(high) * 0.1, 1)
        return (low - pad) ... (high + pad)
    }

    /// The last step: up or down when it moves more than a twentieth of the
    /// row's extent, steady otherwise.
    static func trend(_ points: [TimelinePlotPoint], domain: ClosedRange<Double>) -> TimelineTrend {
        guard points.count >= 2 else { return .unknown }
        let last = points[points.count - 1].value
        let previous = points[points.count - 2].value
        let threshold = (domain.upperBound - domain.lowerBound) / 20
        if last - previous > threshold { return .rising }
        if previous - last > threshold { return .falling }
        return .steady
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, for an array
    /// ordered so that every such element comes after every other one.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
