import Foundation

/// Largest-Triangle-Three-Buckets (LTTB) downsampling.
///
/// **Why a second downsampler next to `SeriesDownsampler`:**
/// `SeriesDownsampler` collapses a series into calendar buckets (mean per
/// day / week). That keeps the *count* down but the arithmetic mean smears
/// peaks and troughs — a glucose spike or a BP outlier averages away into a
/// flat line. LTTB instead keeps the points that contribute the most to the
/// visible *shape* (the ones forming the largest triangles with their
/// neighbours), so the rendered curve stays faithful to the raw data while
/// still dropping to a bounded `threshold` of marks. This is the algorithm
/// Apple Health and Grafana use for long-window charts.
///
/// Reference: Sveinn Steinarsson, "Downsampling Time Series for Visual
/// Representation" (MSc thesis, University of Iceland, 2013), §4.2.
///
/// The implementation is a pure, `Sendable` enum of static functions on
/// value types so it composes inside `ChartDetailStore.makeSeries` without
/// an actor hop — same shape as `SeriesDownsampler`.
public enum LTTB {
    /// A 2-D sample for the generic core algorithm. `x` is the horizontal
    /// axis (time, as a `Double` — e.g. `Date.timeIntervalSinceReferenceDate`)
    /// and `y` the plotted value. Kept tiny + `Sendable` so the algorithm is
    /// pure and trivially testable without the domain `SeriesPoint`.
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Downsamples `points` to at most `threshold` samples using LTTB.
    ///
    /// **Contract:**
    /// - The first and last input points are always retained verbatim
    ///   (LTTB anchors the endpoints).
    /// - Input is assumed already sorted ascending by `x`; the relative
    ///   order is preserved (the output `x` sequence stays monotonic when
    ///   the input is).
    /// - No-op (`points` returned unchanged) when `threshold < 3` or when
    ///   `points.count <= threshold` — there is nothing to gain by bucketing
    ///   a series that is already at or below the target.
    ///
    /// - Parameters:
    ///   - points: the full-resolution series, ascending by `x`.
    ///   - threshold: the maximum number of points to keep. Values `< 3`
    ///     short-circuit to the identity (LTTB needs at least the two
    ///     endpoints plus one bucket).
    /// - Returns: a series of `count <= threshold` points preserving the
    ///   visual shape, or the input unchanged when no downsampling applies.
    public static func downsample(_ points: [Point], threshold: Int) -> [Point] {
        let indices = selectedIndices(points, threshold: threshold)
        // Identity short-circuit: `selectedIndices` returns the full index
        // range when no downsampling applies, so reuse the input directly.
        guard indices.count < points.count else { return points }
        return indices.map { points[$0] }
    }

    /// Core LTTB: returns the **indices** of the points to keep, in ascending
    /// order. Exposed so a domain mapper (``downsampleSeries(_:threshold:)``)
    /// can re-project the survivors onto their original rich points by index —
    /// avoiding any fragile value-equality / x-matching round-trip.
    ///
    /// Same contract as ``downsample(_:threshold:)``: endpoints always
    /// retained; identity (`0 ..< points.count` mapped to an array) when
    /// `threshold < 3` or `points.count <= threshold`.
    public static func selectedIndices(_ points: [Point], threshold: Int) -> [Int] {
        guard threshold >= 3, points.count > threshold else {
            return Array(points.indices)
        }

        var sampled: [Int] = []
        sampled.reserveCapacity(threshold)

        // The first point is always kept (`a` is the previously selected
        // point index, starts at 0).
        sampled.append(0)
        var a = 0

        // Bucket size for the inner `threshold - 2` points (endpoints are
        // handled separately). `Double` so fractional bucket boundaries
        // distribute the rounding error evenly across the range.
        let bucketSize = Double(points.count - 2) / Double(threshold - 2)

        for i in 0 ..< (threshold - 2) {
            // Range of the *next* bucket, over which the average point that
            // forms the apex of the candidate triangles is computed.
            let avgRangeStart = Int(floor(Double(i + 1) * bucketSize)) + 1
            var avgRangeEnd = Int(floor(Double(i + 2) * bucketSize)) + 1
            avgRangeEnd = min(avgRangeEnd, points.count)

            let avgRangeLength = avgRangeEnd - avgRangeStart
            var avgX = 0.0
            var avgY = 0.0
            if avgRangeLength > 0 {
                for j in avgRangeStart ..< avgRangeEnd {
                    avgX += points[j].x
                    avgY += points[j].y
                }
                avgX /= Double(avgRangeLength)
                avgY /= Double(avgRangeLength)
            } else {
                // Degenerate tail bucket — fall back to the last point so the
                // triangle math stays well-defined.
                avgX = points[points.count - 1].x
                avgY = points[points.count - 1].y
            }

            // Range of the *current* bucket from which we pick the point that
            // maximises the triangle area with `a` (selected) and the next
            // bucket's average.
            let rangeStart = Int(floor(Double(i) * bucketSize)) + 1
            var rangeEnd = Int(floor(Double(i + 1) * bucketSize)) + 1
            rangeEnd = min(rangeEnd, points.count)

            let pointA = points[a]
            var maxArea = -1.0
            var nextA = rangeStart

            for j in rangeStart ..< max(rangeStart + 1, rangeEnd) where j < points.count {
                // Twice the triangle area (the factor of 2 + the abs are
                // monotonic so they don't change which point wins).
                let area = abs(
                    (pointA.x - avgX) * (points[j].y - pointA.y)
                        - (pointA.x - points[j].x) * (avgY - pointA.y)
                ) * 0.5
                if area > maxArea {
                    maxArea = area
                    nextA = j
                }
            }

            sampled.append(nextA)
            a = nextA
        }

        // The last point is always kept.
        sampled.append(points.count - 1)
        return sampled
    }

    /// Default plotting threshold for the chart-detail surface.
    ///
    /// `ChartDetailStore` hands at most `seriesPlotThreshold` points to
    /// SwiftUI Charts. The value is chosen so a 393 pt-wide iPhone chart
    /// (≈ 0.75 px per logical point at 3× ≈ 1170 px) never plots more marks
    /// than there are device pixels — past that, extra marks add hit-testing
    /// and interpolation cost without a single visible difference. 500 sits
    /// comfortably above the typical 1-year daily series (≤ 365) so common
    /// ranges pass through untouched, and well below the multi-thousand-point
    /// `.all` / dense-BP payloads that make the long-window chart stutter.
    public static let seriesPlotThreshold = 500

    /// Domain convenience: downsample a `[SeriesPoint]` series for plotting.
    ///
    /// Maps each `SeriesPoint` onto the generic `Point` core (using the
    /// timestamp as `x` and the primary `value` as `y` — the curve LTTB
    /// optimises is the primary line), runs LTTB, then re-projects the
    /// surviving samples back onto their original `SeriesPoint`s by identity.
    /// Because LTTB only ever *selects* existing points (it never synthesises
    /// new ones), each retained sample maps back to a real `SeriesPoint` —
    /// preserving its `id`, exact `at`, and `secondary` (BP diastolic) verbatim
    /// so chart selection + the BP second line stay intact.
    ///
    /// - Parameters:
    ///   - points: the full-resolution `SeriesPoint`s (ascending by `at`).
    ///   - threshold: max points to keep; defaults to ``seriesPlotThreshold``.
    /// - Returns: a `count <= threshold` subset, or the input unchanged when
    ///   `points.count <= threshold`.
    public static func downsampleSeries(
        _ points: [SeriesPoint],
        threshold: Int = seriesPlotThreshold
    ) -> [SeriesPoint] {
        guard threshold >= 3, points.count > threshold else { return points }

        // Project to the generic core, run LTTB, then re-project the surviving
        // indices onto their original `SeriesPoint`s. Because the core works in
        // index space (`selectedIndices`), every survivor maps back to a real
        // `SeriesPoint` — preserving `id`, exact `at`, and `secondary` (BP
        // diastolic) verbatim, with no fragile value-matching round-trip.
        let projected = points.map { Point(x: $0.at.timeIntervalSinceReferenceDate, y: $0.value) }
        let kept = selectedIndices(projected, threshold: threshold)
        return kept.map { points[$0] }
    }
}
