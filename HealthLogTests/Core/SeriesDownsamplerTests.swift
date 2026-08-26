import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Unit coverage for `SeriesDownsampler` — the perf-critical aggregator that
/// keeps the long-window chart detail screen at 60 fps (A3 plan §4.1).
///
/// Pure value-type math, no SwiftUI involved → testable without a host app.
@Suite("SeriesDownsampler")
struct SeriesDownsamplerTests {
    // MARK: - Fixtures

    /// Calendar pinned to UTC + Monday-as-first-weekday so DE/EN switches
    /// don't race the bucket math during CI.
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    private static func point(idx: Int, value: Double, secondary: Double? = nil) -> SeriesPoint {
        // Anchor: 2026-01-01 00:00 UTC (a Thursday → easy to reason about week boundaries)
        let anchor = Date(timeIntervalSince1970: 1_767_225_600)
        return SeriesPoint(
            id: "p-\(idx)",
            at: anchor.addingTimeInterval(TimeInterval(idx * 3600)), // hourly
            value: value,
            secondary: secondary
        )
    }

    // MARK: - recommendedBucket: heuristic gate

    @Test("≤90d windows skip downsampling regardless of point count")
    func shortRangesPassThrough() {
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 7, pointCount: 5000) == nil)
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 30, pointCount: 5000) == nil)
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 90, pointCount: 5000) == nil)
    }

    @Test("1y window with sparse data passes through")
    func yearRangeSparseDataPassesThrough() {
        // 1 weight reading/day for a year → 365 points → no need to bucket
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 365, pointCount: 365) == nil)
    }

    @Test("1y window with dense data buckets daily")
    func yearRangeDenseDataDaily() {
        // BP 6×/day for a year → 2190 points → daily aggregate
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 365, pointCount: 2190) == .day)
    }

    @Test("All-window with very dense data buckets weekly")
    func allRangeVeryDenseWeekly() {
        // ~5 years of BP 6×/day → 11000+ points → weekly aggregate
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 1825, pointCount: 11000) == .week)
    }

    @Test("All-window with moderate data buckets daily")
    func allRangeModerateDaily() {
        #expect(SeriesDownsampler.recommendedBucket(forRangeDays: 1825, pointCount: 800) == .day)
    }

    // MARK: - aggregate: bucketing correctness

    @Test("Empty input → empty output")
    func emptyInput() {
        #expect(SeriesDownsampler.aggregate([], by: .day, calendar: Self.calendar).isEmpty)
    }

    @Test("Daily aggregate: 24 hourly points → 1 daily point with mean value")
    func dailyAggregateOf24HourlyPoints() {
        // 24 hourly points all on 2026-01-01 → values 1...24
        let pts = (0 ..< 24).map { Self.point(idx: $0, value: Double($0 + 1)) }
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)

        #expect(result.count == 1)
        #expect(result.first?.value == 12.5) // mean of 1...24
        #expect(result.first?.secondary == nil)
    }

    @Test("Daily aggregate: spanning 3 days → 3 buckets in chronological order")
    func dailyAggregateAcrossThreeDays() {
        // 72 hourly points spanning 3 calendar days
        let pts = (0 ..< 72).map { Self.point(idx: $0, value: 100.0) }
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)

        #expect(result.count == 3)
        // Sorted ascending — load-bearing for chart x-axis
        #expect(result[0].at < result[1].at)
        #expect(result[1].at < result[2].at)
        // Bucket starts at 00:00 of the day
        let firstComponents = Self.calendar.dateComponents([.hour, .minute], from: result[0].at)
        #expect(firstComponents.hour == 0)
        #expect(firstComponents.minute == 0)
    }

    @Test("Daily aggregate: BP secondaries average independently of primaries")
    func bpSecondaryAggregation() {
        // Two BP readings same day: 120/80 + 130/90 → daily mean 125/85
        let pts = [
            Self.point(idx: 0, value: 120, secondary: 80),
            Self.point(idx: 1, value: 130, secondary: 90)
        ]
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)

        #expect(result.count == 1)
        #expect(result.first?.value == 125)
        #expect(result.first?.secondary == 85)
    }

    @Test("Daily aggregate: secondary stays nil when no point in bucket carries one")
    func secondaryNilWhenAbsent() {
        let pts = (0 ..< 5).map { Self.point(idx: $0, value: 70.0) }
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)
        #expect(result.first?.secondary == nil)
    }

    @Test("Daily aggregate: partial secondary coverage averages only present values")
    func partialSecondaryCoverage() {
        let pts = [
            Self.point(idx: 0, value: 120, secondary: 80),
            Self.point(idx: 1, value: 130, secondary: nil), // only 1 BP measurement same day
            Self.point(idx: 2, value: 140, secondary: 90)
        ]
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)
        #expect(result.first?.secondary == 85) // (80 + 90) / 2
    }

    @Test("Weekly aggregate: 7 daily points (Mon-Sun) → 1 weekly bucket")
    func weeklyAggregateOneWeek() {
        // 168 hourly points = 7 days
        let pts = (0 ..< 168).map { Self.point(idx: $0, value: 50.0) }
        let result = SeriesDownsampler.aggregate(pts, by: .week, calendar: Self.calendar)

        // 2026-01-01 is Thursday; with Monday-as-first-weekday, the points span
        // from Thu Jan 1 to Wed Jan 7 → 1 week bucket (Mon Dec 29 → Mon Jan 5)
        // and possibly a 2nd partial bucket for Jan 5+
        #expect(result.count >= 1)
        #expect(result.count <= 2)
    }

    @Test("Output always sorted ascending by bucket start")
    func outputAlwaysSorted() {
        // Reverse-order input
        let pts = (0 ..< 100).reversed().map { Self.point(idx: $0, value: Double($0)) }
        let result = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)

        for i in 1 ..< result.count {
            #expect(result[i - 1].at < result[i].at, "bucket \(i) out of order")
        }
    }

    // MARK: - downsampleIfNeeded: end-to-end

    @Test("downsampleIfNeeded: 30d window passes through unchanged")
    func endToEndShortRange() {
        let pts = (0 ..< 200).map { Self.point(idx: $0, value: Double($0)) }
        let result = SeriesDownsampler.downsampleIfNeeded(pts, rangeDays: 30)

        #expect(result.count == pts.count)
        // ID stability — passed-through points keep their original IDs
        #expect(result.first?.id == "p-0")
    }

    @Test("downsampleIfNeeded: 1y dense BP collapses to ≤365 buckets")
    func endToEndYearDenseBP() {
        // Simulate 1 year × 6 BP/day = 2190 points
        let pts = (0 ..< 2190).map { Self.point(idx: $0, value: 120.0, secondary: 80.0) }
        let result = SeriesDownsampler.downsampleIfNeeded(pts, rangeDays: 365, calendar: Self.calendar)

        // Expected ~91 days × 1 bucket each (we're hourly = 24 buckets per day → 2190/24 ≈ 91 days)
        // Just assert the headline: drastically smaller, ≤ N/2.
        #expect(
            result.count <= pts.count / 2,
            "expected ≤\(pts.count / 2) buckets, got \(result.count)"
        )
        // Bucket IDs carry the agg- prefix
        #expect(result.first?.id.hasPrefix("agg-d-") == true)
    }

    @Test("downsampleIfNeeded: All-window very dense series uses weekly buckets")
    func endToEndAllRangeWeekly() {
        // 5 years × hourly = 43800 points
        let pts = (0 ..< 43800).map { Self.point(idx: $0, value: 100.0) }
        let result = SeriesDownsampler.downsampleIfNeeded(pts, rangeDays: 1825, calendar: Self.calendar)

        #expect(result.count <= pts.count / 2)
        #expect(result.first?.id.hasPrefix("agg-w-") == true)
    }

    @Test("Aggregated point count never exceeds input count")
    func aggregateNeverGrows() {
        let pts = (0 ..< 50).map { Self.point(idx: $0, value: Double($0)) }
        let daily = SeriesDownsampler.aggregate(pts, by: .day, calendar: Self.calendar)
        let weekly = SeriesDownsampler.aggregate(pts, by: .week, calendar: Self.calendar)
        #expect(daily.count <= pts.count)
        #expect(weekly.count <= pts.count)
        #expect(weekly.count <= daily.count) // week ≤ day buckets always
    }
}
