import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The pure math behind the intraday day curve (P7). No view, no store, no
/// network — just the rules the surface's honesty depends on:
/// gaps never get bridged, a caveat only fires when there IS a gap, wall-clock
/// labels are raw minutes, and the navigator can never step into the future.
@Suite("IntradayPulse — pure math (runs / coverage / labels / day keys)")
struct IntradayPulseMathTests {
    private func bucket(_ minute: Int, mean: Double = 70, count: Int = 3) -> IntradayPulseDTO.Bucket {
        IntradayPulseDTO.Bucket(startMinute: minute, mean: mean, count: count)
    }

    private var berlin: TimeZone {
        TimeZone(identifier: "Europe/Berlin")!
    }

    // MARK: - Run splitting

    @Test("runs — a fully contiguous series is ONE run")
    func contiguousIsOneRun() {
        let series = [bucket(0), bucket(10), bucket(20), bucket(30)]
        let runs = IntradayPulseMath.runs(series, bucketMinutes: 10)
        #expect(runs.count == 1)
        #expect(runs[0].count == 4)
    }

    @Test("runs — a single missing bucket SPLITS the line (never interpolate)")
    func oneGapSplits() {
        // 0,10 … [20 missing] … 30,40
        let series = [bucket(0), bucket(10), bucket(30), bucket(40)]
        let runs = IntradayPulseMath.runs(series, bucketMinutes: 10)
        #expect(runs.count == 2)
        #expect(runs[0].map(\.startMinute) == [0, 10])
        #expect(runs[1].map(\.startMinute) == [30, 40])
    }

    @Test("runs — scattered spot readings are all isolated single-bucket runs")
    func scatteredPointsAreSingletons() {
        let series = [bucket(60), bucket(480), bucket(1200)]
        let runs = IntradayPulseMath.runs(series, bucketMinutes: 10)
        #expect(runs.count == 3)
        #expect(runs.allSatisfy { $0.count == 1 })
    }

    @Test("runs — an out-of-order series is sorted before splitting")
    func unsortedInputStillSplitsCorrectly() {
        let series = [bucket(30), bucket(0), bucket(10)]
        let runs = IntradayPulseMath.runs(series, bucketMinutes: 10)
        #expect(runs.count == 2)
        #expect(runs[0].map(\.startMinute) == [0, 10])
    }

    @Test("runs — hourly grain treats 60-minute steps as contiguous")
    func hourlyGrainContiguous() {
        let series = [bucket(0), bucket(60), bucket(120)]
        #expect(IntradayPulseMath.runs(series, bucketMinutes: 60).count == 1)
        // At 10-minute grain the SAME rows are three separate readings.
        #expect(IntradayPulseMath.runs(series, bucketMinutes: 10).count == 3)
    }

    @Test("runs — empty series yields no runs")
    func emptySeriesNoRuns() {
        #expect(IntradayPulseMath.runs([], bucketMinutes: 10).isEmpty)
    }

    // MARK: - Coverage disclosure

    @Test("coverage — a gap-free day needs no caveat")
    func contiguousDayNoCoverage() {
        let series = [bucket(0), bucket(10), bucket(20)]
        #expect(IntradayPulseMath.coverage(series, bucketMinutes: 10) == nil)
    }

    @Test("coverage — a single bucket is not enough to speak about coverage")
    func singleBucketNoCoverage() {
        #expect(IntradayPulseMath.coverage([bucket(0)], bucketMinutes: 10) == nil)
    }

    @Test("coverage — a gap reports the reading count and whole-hour span")
    func gapReportsCoverage() {
        // 09:00 (2 readings) … gap … 12:00 (4 readings). Span 540 → 730 = 190 min ≈ 3 h.
        let series = [bucket(540, count: 2), bucket(720, count: 4)]
        let coverage = IntradayPulseMath.coverage(series, bucketMinutes: 10)
        #expect(coverage == IntradayPulseMath.Coverage(readingCount: 6, hours: 3))
    }

    @Test("coverage — a sub-hour span still rounds up to one whole hour")
    func shortSpanFloorsAtOneHour() {
        let series = [bucket(0, count: 1), bucket(30, count: 1)]
        let coverage = IntradayPulseMath.coverage(series, bucketMinutes: 10)
        #expect(coverage?.hours == 1)
        #expect(coverage?.readingCount == 2)
    }

    // MARK: - Wall-clock labels

    @Test("minuteLabel — raw wall time, zero padded, 24:00 at the right edge")
    func minuteLabels() {
        #expect(IntradayPulseMath.minuteLabel(0) == "00:00")
        #expect(IntradayPulseMath.minuteLabel(540) == "09:00")
        #expect(IntradayPulseMath.minuteLabel(725) == "12:05")
        #expect(IntradayPulseMath.minuteLabel(1440) == "24:00")
        #expect(IntradayPulseMath.axisTicks == [0, 360, 720, 1080, 1440])
    }

    // MARK: - Day keys + navigator

    @Test("dayKey — resolved in the PROFILE zone, not the device zone")
    func dayKeyUsesProfileZone() throws {
        // 2026-07-24 23:30 UTC is already the 25th in Berlin (UTC+2).
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 24
        components.hour = 23
        components.minute = 30
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(utcCalendar.date(from: components))
        #expect(IntradayPulseMath.dayKey(for: date, in: berlin) == "2026-07-25")
        #expect(try IntradayPulseMath.dayKey(for: date, in: #require(TimeZone(identifier: "UTC"))) == "2026-07-24")
    }

    @Test("shift — steps whole days across the spring DST boundary")
    func shiftAcrossDST() {
        // Europe/Berlin springs forward on 2026-03-29 (a 23-hour day).
        #expect(IntradayPulseMath.shift(dayKey: "2026-03-28", by: 1, in: berlin) == "2026-03-29")
        #expect(IntradayPulseMath.shift(dayKey: "2026-03-29", by: 1, in: berlin) == "2026-03-30")
        #expect(IntradayPulseMath.shift(dayKey: "2026-03-29", by: -1, in: berlin) == "2026-03-28")
        // …and the autumn fold (a 25-hour day) on 2026-10-25.
        #expect(IntradayPulseMath.shift(dayKey: "2026-10-25", by: -1, in: berlin) == "2026-10-24")
        #expect(IntradayPulseMath.shift(dayKey: "2026-10-25", by: 1, in: berlin) == "2026-10-26")
    }

    @Test("shift — an unparsable key yields nil, never a fabricated day")
    func shiftRejectsGarbage() {
        #expect(IntradayPulseMath.shift(dayKey: "nonsense", by: -1, in: berlin) == nil)
    }

    @Test("nextDayKey — capped at today (defence in depth beside the disabled chevron)")
    func nextDayCappedAtToday() {
        #expect(
            IntradayPulseMath.nextDayKey(after: "2026-07-22", todayKey: "2026-07-24", in: berlin)
                == "2026-07-23"
        )
        #expect(
            IntradayPulseMath.nextDayKey(after: "2026-07-23", todayKey: "2026-07-24", in: berlin)
                == "2026-07-24"
        )
        // Already on today → no step at all.
        #expect(IntradayPulseMath.nextDayKey(after: "2026-07-24", todayKey: "2026-07-24", in: berlin) == nil)
    }
}

// swiftlint:enable force_unwrapping
