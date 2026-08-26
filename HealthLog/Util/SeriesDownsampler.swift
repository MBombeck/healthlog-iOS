import Foundation

/// Pure-function aggregator that collapses a long `[SeriesPoint]` series into
/// fewer buckets so SwiftUI Charts stays smooth past ~1.5k marks.
///
/// **Why:** `chartXSelection` hit-testing + `LineMark` interpolation degrade fast
/// once the point count crosses ~1500 on an A15-class device. Apple's Health app
/// solves this by switching to per-day / per-week aggregates beyond a threshold;
/// this type ports the same idea client-side until the server exposes a
/// `?aggregate=daily|weekly` query param on `/api/measurements/series`.
///
/// The aggregation is intentionally a single sync function on value types so
/// it composes inside `ChartsStore.load` without an actor hop.
public enum SeriesDownsampler {
    /// Bucket window for `aggregate(_:by:)`.
    public enum Bucket: Sendable {
        case day
        case week
    }

    /// Strategy decision per range — keeps the heuristic in one place so callers
    /// (`ChartsStore`, `ChartDetailStore`) stay agreeing.
    ///
    /// - Parameters:
    ///   - days: chart range in days (7, 30, 90, 365, …).
    ///   - pointCount: number of points the server returned (NOT a hard cap; see notes).
    /// - Returns: `nil` if no downsampling is needed, otherwise the bucket window.
    public static func recommendedBucket(forRangeDays days: Int, pointCount: Int) -> Bucket? {
        // ≤90d: the user wants to see individual readings (esp. BP, glucose
        // where 4–6 datapoints/day is meaningful). Don't downsample.
        if days <= 90 { return nil }
        // 1y window: collapse to daily aggregates only if the raw payload is
        // large enough that per-point rendering would stutter. Some metrics
        // (weight) only have one point per day to begin with.
        if days <= 365 {
            return pointCount > 500 ? .day : nil
        }
        // "All": daily for moderate sets, weekly once we cross the high-water mark.
        return pointCount > 1500 ? .week : .day
    }

    /// Aggregates `points` into one bucket per calendar day (or week).
    ///
    /// Each bucket emits a single `SeriesPoint` with:
    /// - `id`: derived from the bucket key (stable across re-renders so SwiftUI
    ///   Charts keeps animating instead of re-mounting).
    /// - `at`: the bucket-start timestamp (start-of-day or start-of-week).
    /// - `value`: arithmetic mean of the bucket's primary values.
    /// - `secondary`: arithmetic mean of secondary values (BP diastolic), or
    ///   `nil` if no point in the bucket carried one.
    ///
    /// Empty input → empty output. Single-point buckets pass through unchanged.
    public static func aggregate(
        _ points: [SeriesPoint],
        by bucket: Bucket,
        calendar: Calendar = .current
    ) -> [SeriesPoint] {
        guard !points.isEmpty else { return [] }

        var grouped: [Date: [SeriesPoint]] = [:]
        for point in points {
            let key = bucketStart(of: point.at, bucket: bucket, calendar: calendar)
            grouped[key, default: []].append(point)
        }

        return grouped.sorted { $0.key < $1.key }.map { key, bucketPoints in
            let primary = bucketPoints.map(\.value).reduce(0, +) / Double(bucketPoints.count)
            let secondaries = bucketPoints.compactMap(\.secondary)
            let secondary: Double? = secondaries.isEmpty
                ? nil
                : secondaries.reduce(0, +) / Double(secondaries.count)
            // ID prefix encodes the bucket — guards against collisions if a
            // future caller mixes daily + weekly buckets in the same view.
            let prefix = switch bucket {
            case .day: "agg-d"
            case .week: "agg-w"
            }
            return SeriesPoint(
                id: "\(prefix)-\(Int(key.timeIntervalSince1970))",
                at: key,
                value: primary,
                secondary: secondary
            )
        }
    }

    /// Convenience: pick the bucket via `recommendedBucket(forRangeDays:pointCount:)`,
    /// then aggregate (or pass through unchanged).
    public static func downsampleIfNeeded(
        _ points: [SeriesPoint],
        rangeDays: Int,
        calendar: Calendar = .current
    ) -> [SeriesPoint] {
        guard let bucket = recommendedBucket(forRangeDays: rangeDays, pointCount: points.count) else {
            return points
        }
        return aggregate(points, by: bucket, calendar: calendar)
    }

    // MARK: - Helpers

    private static func bucketStart(of date: Date, bucket: Bucket, calendar: Calendar) -> Date {
        switch bucket {
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            // ISO-week-ish: use the calendar's first weekday (locale-aware) so DE
            // (Monday) and EN (Sunday) bucket correctly; `dateInterval(of:.weekOfYear, ...)`
            // returns the canonical week-start for the current calendar.
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }
}
