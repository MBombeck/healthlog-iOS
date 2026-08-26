import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `ChartDetailStore` — focuses on pure-function additions from the
/// Charlie v0.4.0 polish. The store itself is `@MainActor @Observable` with
/// `private(set)` outputs, so non-pure state is covered via the existing
/// integration-style flows (`MeasurementsRepositorySeriesTests` etc.).
@Suite("ChartDetailStore — Charlie v0.4.0 polish")
struct ChartDetailStoreTests {
    // MARK: - Range vocabulary (Apple-Health-style segmented picker)

    @Test("Range labels match Apple-Health vocabulary")
    func rangeLabelsAppleHealthVocabulary() {
        let labels = ChartDetailStore.Range.allCases.map(\.label)
        // Apple Health uses T (Tag) / W (Woche) / M (Monat) / 6M / J (Jahr)
        // — single short letter for the simple cases keeps the segmented
        // picker readable at AX text sizes. v0.7.0 W-STEPS appends "Alle"
        // (all-time) so the operator can pull the full history.
        #expect(labels == ["T", "W", "M", "6M", "J", "Alle"])
    }

    @Test("Range rawValue == window size in days")
    func rangeRawValueIsDays() {
        #expect(ChartDetailStore.Range.day.rawValue == 1)
        #expect(ChartDetailStore.Range.week.rawValue == 7)
        #expect(ChartDetailStore.Range.month.rawValue == 30)
        #expect(ChartDetailStore.Range.sixMonths.rawValue == 180)
        #expect(ChartDetailStore.Range.year.rawValue == 365)
        // v0.7.0 W-STEPS — `.all` rawValue doubles as the `series(days:)`
        // window; ~10y covers any realistic HK history.
        #expect(ChartDetailStore.Range.all.rawValue == 3650)
    }

    @Test("Range accessibility labels read as full words (VoiceOver)")
    func rangeAccessibilityLabelsReadable() {
        // VoiceOver should speak "Woche" not "W". The segmented picker hides
        // the short label behind `.accessibilityLabel(...)` so the rotor
        // experience stays readable.
        #expect(ChartDetailStore.Range.day.accessibilityLabel.contains("Tag"))
        #expect(ChartDetailStore.Range.week.accessibilityLabel.contains("Woche"))
        #expect(ChartDetailStore.Range.month.accessibilityLabel.contains("Monat"))
        #expect(ChartDetailStore.Range.sixMonths.accessibilityLabel.contains("Monate"))
        #expect(ChartDetailStore.Range.year.accessibilityLabel.contains("Jahr"))
    }
}

/// Pure median helper — the on-device statistic added to the summary header
/// in Charlie v0.4.0. The server's `SeriesStats` doesn't carry median, so we
/// compute it client-side. Tests pin the math against odd/even sample counts
/// + outlier resistance (the reason median is preferable to mean).
@Suite("ChartDetailStore.median(of:)")
struct ChartDetailStoreMedianTests {
    @Test("Median of odd count returns middle value")
    func medianOddCount() {
        // 70, 71, 72, 73, 74 → middle index 2 = 72
        #expect(ChartDetailStore.median(of: [70.0, 71.0, 72.0, 73.0, 74.0]) == 72.0)
    }

    @Test("Median of even count averages the two middle values")
    func medianEvenCount() {
        // 70, 71, 72, 73 → (71 + 72) / 2 = 71.5
        #expect(ChartDetailStore.median(of: [70.0, 71.0, 72.0, 73.0]) == 71.5)
    }

    @Test("Median is outlier-resistant (vs mean)")
    func medianResistantToOutliers() {
        // 70, 71, 72, 73, 74, 200 → median = (72 + 73) / 2 = 72.5
        // (mean would be 93.3 — skewed massively by the outlier)
        #expect(ChartDetailStore.median(of: [70, 71, 72, 73, 74, 200]) == 72.5)
    }

    @Test("Empty input → median is nil")
    func medianNilForEmpty() {
        #expect(ChartDetailStore.median(of: []) == nil)
    }

    @Test("Single value → median is that value")
    func medianSingleValue() {
        #expect(ChartDetailStore.median(of: [42.0]) == 42.0)
    }

    @Test("Unsorted input is sorted before median lookup")
    func medianHandlesUnsortedInput() {
        // 5, 1, 3, 2, 4 → sorted = 1, 2, 3, 4, 5 → median = 3
        #expect(ChartDetailStore.median(of: [5.0, 1.0, 3.0, 2.0, 4.0]) == 3.0)
    }
}

/// v0.7.0 W-API-RENDER — HeroStrip trend decoration derived from the
/// comprehensive digest's per-metric `MetricSummary`. The store dropped
/// every slope + the year-ago baseline before this wave; these tests pin
/// the pure derivation helpers the HeroStrip consumes.
@Suite("ChartDetailStore — trend + year-over-year decoration")
struct ChartDetailStoreTrendTests {
    @Test("trendSlopes preserves 7/30/90 order and skips omitted windows")
    func trendSlopesOrdering() {
        let summary = MetricSummary(
            slope7: TrendSlope(slope: -0.04, direction: .down),
            slope30: nil,
            slope90: TrendSlope(slope: 0.01, direction: .up)
        )
        let slopes = ChartDetailStore.trendSlopes(from: summary)
        #expect(slopes.count == 2)
        #expect(slopes[0].window == .week)
        #expect(slopes[0].slope.direction == .down)
        #expect(slopes[1].window == .quarter)
        #expect(slopes[1].slope.direction == .up)
    }

    @Test("trendSlopes is empty when no summary landed")
    func trendSlopesEmptyWithoutSummary() {
        #expect(ChartDetailStore.trendSlopes(from: nil).isEmpty)
    }

    @Test("deltaVsLastYear subtracts the year-ago baseline from the current avg30")
    func deltaUsesAvg30() {
        let summary = MetricSummary(latest: 78.0, avg30: 79.2, avg30LastYear: 81.5)
        let delta = ChartDetailStore.deltaVsLastYear(from: summary)
        #expect(delta != nil)
        // 79.2 − 81.5 = −2.3 (use avg30, not latest)
        #expect(abs((delta ?? 0) + 2.3) < 0.0001)
    }

    @Test("deltaVsLastYear falls back to latest when avg30 is absent")
    func deltaFallsBackToLatest() {
        let summary = MetricSummary(latest: 78.0, avg30: nil, avg30LastYear: 80.0)
        let delta = ChartDetailStore.deltaVsLastYear(from: summary)
        #expect(abs((delta ?? 0) + 2.0) < 0.0001)
    }

    @Test("deltaVsLastYear is nil without a year-ago baseline")
    func deltaNilWithoutBaseline() {
        let summary = MetricSummary(latest: 78.0, avg30: 79.0, avg30LastYear: nil)
        #expect(ChartDetailStore.deltaVsLastYear(from: summary) == nil)
    }
}

/// QC-2 reconcile — chart-detail must skip the `/api/measurements/series`
/// network call for kinds the server doesn't support, otherwise the
/// surface emits a spurious 422 on every load. Mirrors the dashboard
/// gate (`DashboardStore.kindSupportsSeries`).
@Suite("ChartDetailStore.kindSupportsSeries — server-supported metric gate")
struct ChartDetailStoreKindSupportTests {
    @Test("bodyTemperature is the only kind currently unsupported")
    func bodyTemperatureUnsupported() {
        #expect(ChartDetailStore.kindSupportsSeries(.bodyTemperature) == false)
    }

    @Test("Every other MetricKind is server-series-supported")
    func otherKindsSupported() {
        let supported: [MetricKind] = [
            .weight, .bloodPressure, .pulse, .glucose, .bodyFat,
            .spo2, .bodyWater, .boneMass, .sleep, .steps
        ]
        for kind in supported {
            #expect(ChartDetailStore.kindSupportsSeries(kind) == true, "Expected \(kind.rawValue) to support series")
        }
    }
}

/// W-WORKOUT-E2E (2026-06-11) — cross-source non-summing pin. When HealthKit
/// (live, on-device) AND the server (synced sources: Apple Health upload,
/// Withings, WHOOP…) both cover today's cumulative metric, the dashboard /
/// chart-detail must show ONE source's value — the live HK total *replaces*
/// the server datapoint, it is never *added* on top. The server applies the
/// same rule via the per-day source-priority ladder pick; this suite pins the
/// iOS half so a future refactor can't silently turn the overlay into a sum.
@Suite("ChartDetailStore.replacingTodayValue — live HK value replaces, never sums")
@MainActor
struct ChartDetailStoreLiveTodayReplaceTests {
    private func point(id: String, at: Date, value: Double) -> SeriesPoint {
        SeriesPoint(id: id, at: at, value: value, secondary: nil)
    }

    @Test("Today's point carries exactly the live value — server value is replaced, not summed")
    func todayReplacedNotSummed() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = try #require(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: dayStart))

        let serverToday = 4200.0 // stale server snapshot (e.g. Apple Health upload)
        let liveHK = 6814.0 // fresh HK-direct total (same physical steps)
        let points = [
            point(id: "p-yest", at: yesterday, value: 9000),
            point(id: "p-today", at: dayStart.addingTimeInterval(60), value: serverToday)
        ]

        let patched = ChartDetailStore.replacingTodayValue(
            in: points, liveValue: liveHK, dayStart: dayStart, dayEnd: dayEnd
        )

        let today = patched.first { $0.id == "p-today" }
        #expect(today?.value == liveHK, "live HK total must replace the server value")
        #expect(today?.value != serverToday + liveHK, "sources must never be summed")
    }

    @Test("Points outside today stay byte-identical (history untouched)")
    func historyUntouched() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = try #require(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: dayStart))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: dayStart))

        let points = [
            point(id: "a", at: twoDaysAgo, value: 7500),
            point(id: "b", at: yesterday, value: 9000)
        ]
        let patched = ChartDetailStore.replacingTodayValue(
            in: points, liveValue: 1234, dayStart: dayStart, dayEnd: dayEnd
        )
        #expect(patched.map(\.value) == [7500, 9000])
        #expect(patched.map(\.id) == ["a", "b"])
    }

    @Test("Multiple today-slices each replaced with the SAME day total (no per-slice accumulation)")
    func multipleTodaySlicesNotAccumulated() throws {
        // Defensive: if the server ever delivered intra-day slices, each slice
        // is overwritten with the day total — the overlay must not produce a
        // chart whose slices sum to N × the live value being *added* onto the
        // server slices. (Day-granularity series carry one point per day; this
        // pins the degenerate case anyway.)
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = try #require(calendar.date(byAdding: .day, value: 1, to: dayStart))

        let points = [
            point(id: "s1", at: dayStart.addingTimeInterval(3600), value: 1000),
            point(id: "s2", at: dayStart.addingTimeInterval(7200), value: 2000)
        ]
        let patched = ChartDetailStore.replacingTodayValue(
            in: points, liveValue: 5000, dayStart: dayStart, dayEnd: dayEnd
        )
        #expect(patched.map(\.value) == [5000, 5000])
    }
}
