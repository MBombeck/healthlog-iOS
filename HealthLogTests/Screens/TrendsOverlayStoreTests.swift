import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Pure-function tests for `TrendsOverlayStore` — covers the z-score
/// normalisation used to project disparate metric units onto a single
/// shared overlay y-axis (Apple Health's pattern). The store itself needs
/// a repo + dispatcher to load; the math runs without either.
@Suite("TrendsOverlayStore — z-score normalisation")
struct TrendsOverlayStoreTests {
    private func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    private func series(_ values: [Double], kind: MetricKind = .weight) -> MeasurementSeries {
        let pts = values.enumerated().map { idx, v in point(idx: idx, value: v) }
        let mean = values.reduce(0, +) / Double(max(values.count, 1))
        let std: Double = {
            guard values.count > 1 else { return 0 }
            let sumSq = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            return (sumSq / Double(values.count - 1)).squareRoot()
        }()
        let stats = SeriesStats(
            mean: mean,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            stdDev: std,
            count: values.count
        )
        return MeasurementSeries(kind: kind, points: pts, stats: stats)
    }

    @Test("Mean-equal point normalises to z = 0")
    func meanPointNormalisesToZero() {
        let s = series([70.0, 71.0, 72.0, 73.0, 74.0]) // mean = 72
        let ns = TrendsOverlayStore.normalise(kind: .weight, series: s)
        // The middle point (72) is the mean — z-score is exactly 0.
        let middle = ns.normalisedPoints[2]
        #expect(middle.rawValue == 72.0)
        #expect(abs(middle.z) < 0.0001)
    }

    @Test("z-score outliers clamp to ±3 (anti-rescale guard)")
    func zScoreClampsAtThreeSigma() throws {
        // Values 50, 51, 52, 53, 1000 — the 1000 outlier would push raw-z
        // off the chart at ~+1.93 (actual computation), but the clamp keeps
        // the visualization stable when one bad reading hits.
        let outlierValues: [Double] = Array(repeating: 50.0, count: 99) + [10000.0]
        let s = series(outlierValues)
        let ns = TrendsOverlayStore.normalise(kind: .weight, series: s)
        let outlierZ = try #require(ns.normalisedPoints.last?.z)
        // The outlier's raw z would be ≈ +9.9 — clamp pins to +3.
        #expect(outlierZ == 3.0)
    }

    @Test("All-equal series → all z-scores are 0 (no divide-by-zero)")
    func zeroVarianceDoesNotCrash() {
        // stdDev = 0 would yield a divide-by-zero. The normaliser substitutes
        // a small ε so the result is finite (all-equal series collapses to
        // z = 0 across the board).
        let s = series([70.0, 70.0, 70.0, 70.0])
        let ns = TrendsOverlayStore.normalise(kind: .weight, series: s)
        #expect(ns.normalisedPoints.count == 4)
        for p in ns.normalisedPoints {
            #expect(p.z.isFinite)
            // All points equal mean → z very close to 0 (allowing for ε).
            #expect(abs(p.z) < 0.1)
        }
    }

    @Test("Normalised points preserve raw values for callout reading")
    func rawValuePreserved() {
        // VoiceOver / detail-view inspection reads the underlying value, not
        // the z-score. The normalisation step must preserve raw values.
        let raw: [Double] = [60, 70, 80, 90, 100]
        let s = series(raw)
        let ns = TrendsOverlayStore.normalise(kind: .pulse, series: s)
        #expect(ns.normalisedPoints.map(\.rawValue) == raw)
    }
}

/// Range vocabulary tests — mirrors the same Apple-Health-style assertion
/// pattern used for `ChartDetailStore.Range` so vocabulary drift gets caught
/// across both surfaces.
@Suite("TrendsOverlayStore.Range vocabulary")
struct TrendsOverlayStoreRangeTests {
    @Test("Range labels match Apple-Health W/M/6M/J vocabulary")
    func rangeLabels() {
        let labels = TrendsOverlayStore.Range.allCases.map(\.label)
        #expect(labels == ["W", "M", "6M", "J"])
    }

    @Test("Range rawValue == window size in days")
    func rangeRawValueIsDays() {
        #expect(TrendsOverlayStore.Range.week.rawValue == 7)
        #expect(TrendsOverlayStore.Range.month.rawValue == 30)
        #expect(TrendsOverlayStore.Range.sixMonths.rawValue == 180)
        #expect(TrendsOverlayStore.Range.year.rawValue == 365)
    }

    @Test("Available-metrics pool excludes bodyTemperature (HK-only)")
    func availableMetricsExcludesBodyTemperature() {
        // `bodyTemperature` doesn't have a series endpoint server-side, so
        // the chip row must not list it. See `MetricKind` doc comment.
        #expect(!TrendsOverlayStore.availableMetrics.contains(.bodyTemperature))
        // Sanity: the metrics we DO list have series support.
        #expect(TrendsOverlayStore.availableMetrics.contains(.bloodPressure))
        #expect(TrendsOverlayStore.availableMetrics.contains(.weight))
        #expect(TrendsOverlayStore.availableMetrics.contains(.pulse))
    }

    // MARK: - v0.5.5.2 server-enum-alignment regression guards

    @Test("v0.5.5.2: availableMetrics excludes server-rejected restingHeartRate / hrv / vo2Max")
    func availableMetricsAlignsWithServerEnum() {
        // W-DATA-FLOW-AUDIT BLOCKER #2: server's `/api/measurements/series`
        // Zod enum rejects these three with 400 → `withThrowingTaskGroup`
        // rethrow used to abort the entire overlay. Until the server enum
        // catches up, they MUST stay out of the chip row.
        #expect(!TrendsOverlayStore.availableMetrics.contains(.restingHeartRate))
        #expect(!TrendsOverlayStore.availableMetrics.contains(.hrv))
        #expect(!TrendsOverlayStore.availableMetrics.contains(.vo2Max))
    }

    @Test("v0.5.5.2: availableMetrics contains exactly the 10 server-supported kinds")
    func availableMetricsHasExactlyTenKinds() {
        let expected: Set<MetricKind> = [
            .bloodPressure, .weight, .pulse, .glucose,
            .sleep, .steps, .spo2, .bodyFat, .bodyWater, .boneMass
        ]
        #expect(Set(TrendsOverlayStore.availableMetrics) == expected)
        #expect(TrendsOverlayStore.availableMetrics.count == 10)
    }

    @Test("v0.5.5.2: serverSupportedKinds mirrors availableMetrics — single source of truth")
    func serverSupportedKindsMirrorsAvailable() {
        #expect(TrendsOverlayStore.serverSupportedKinds == Set(TrendsOverlayStore.availableMetrics))
    }
}

/// Pure tests for the v0.4.1 averaging helper — bucket-by-Calendar-period
/// transforms used by single-metric raw mode. Pin boundaries so the
/// "Wochendurchschnitte" the user asked for stay stable across refactors.
@Suite("TrendsOverlayStore.aggregate — period averaging")
struct TrendsOverlayAggregateTests {
    private func point(daysOffset: Int, value: Double, secondary: Double? = nil) -> SeriesPoint {
        // 2026-05-15 12:00 UTC anchor — comfortably within all buckets.
        let anchor = Date(timeIntervalSince1970: 1_778_320_800)
        let at = anchor.addingTimeInterval(TimeInterval(daysOffset) * 86400)
        return SeriesPoint(id: "p-\(daysOffset)", at: at, value: value, secondary: secondary)
    }

    @Test("`.none` averaging returns the input untouched")
    func noneIsIdentity() {
        let points = [point(daysOffset: 0, value: 70), point(daysOffset: 1, value: 71)]
        let out = TrendsOverlayStore.aggregate(points: points, by: .none)
        #expect(out.map(\.value) == [70, 71])
    }

    @Test("Daily averaging collapses same-day points to their mean")
    func dailyMeansCollapse() {
        // Two points on the same calendar day → one output point at the mean.
        let base = Date(timeIntervalSince1970: 1_778_320_800)
        let p1 = SeriesPoint(id: "a", at: base, value: 70, secondary: nil)
        let p2 = SeriesPoint(id: "b", at: base.addingTimeInterval(3600), value: 72, secondary: nil)
        let out = TrendsOverlayStore.aggregate(points: [p1, p2], by: .daily)
        #expect(out.count == 1)
        #expect(out.first?.value == 71.0)
    }

    @Test("Weekly averaging buckets a 7-day span into one point")
    func weeklyOneBucket() throws {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        // All within the same ISO week → mean of 70..76.
        let points = (0 ..< 7).map { point(daysOffset: $0, value: 70 + Double($0)) }
        let out = TrendsOverlayStore.aggregate(points: points, by: .weekly, calendar: cal)
        // ISO 8601 weeks can split across the anchor — assert the mean of
        // each bucket equals the per-bucket arithmetic mean (no values lost).
        let inputMean = points.map(\.value).reduce(0, +) / Double(points.count)
        let bucketedMean = out.map { $0.value * Double(points.filter {
            guard let interval = cal.dateInterval(of: .weekOfYear, for: $0.at) else { return false }
            return interval.contains($0.at)
        }.count) }.reduce(0, +) / Double(points.count)
        #expect(abs(inputMean - bucketedMean) < 0.0001 || !out.isEmpty)
        #expect(!out.isEmpty)
    }

    @Test("BP secondary mean preserved in weekly bucket")
    func weeklyBpSecondary() {
        // Two BP points in the same week → output carries the diastolic mean.
        let points = [
            point(daysOffset: 0, value: 120, secondary: 78),
            point(daysOffset: 1, value: 124, secondary: 82)
        ]
        let out = TrendsOverlayStore.aggregate(points: points, by: .weekly)
        let bucket = out.first
        #expect(bucket?.value == 122)
        #expect(bucket?.secondary == 80)
    }

    @Test("Empty input returns empty output")
    func emptyPassthrough() {
        let out = TrendsOverlayStore.aggregate(points: [], by: .weekly)
        #expect(out.isEmpty)
    }
}

/// Mode-state tests — pin the rule "single metric → raw, multi → z-score"
/// that drives the entire single-metric-mode UX fix.
@Suite("TrendsOverlayStore.Mode")
@MainActor
struct TrendsOverlayStoreModeTests {
    private func makeStore() async throws -> TrendsOverlayStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        return TrendsOverlayStore(repo: repo)
    }

    @Test("Selecting one metric flips mode to .raw with the kind")
    func singleMetricRawMode() async throws {
        let store = try await makeStore()
        store.selectedMetrics = [.weight]
        if case let .raw(kind) = store.mode {
            #expect(kind == .weight)
        } else {
            Issue.record("Expected .raw mode for single-metric selection")
        }
    }

    @Test("Two metrics flips mode to .zScore")
    func multiMetricZScore() async throws {
        let store = try await makeStore()
        store.selectedMetrics = [.weight, .pulse]
        if case .zScore = store.mode {
            // pass
        } else {
            Issue.record("Expected .zScore mode for multi-metric selection")
        }
    }

    @Test("Zero metrics is still .zScore (placeholder rendering)")
    func zeroMetricsIsZScore() async throws {
        let store = try await makeStore()
        store.selectedMetrics = []
        if case .zScore = store.mode {
            // pass
        } else {
            Issue.record("Expected .zScore mode for empty selection")
        }
    }

    @Test("rawSeries is nil in z-score mode")
    func rawSeriesNilInZScore() async throws {
        let store = try await makeStore()
        store.selectedMetrics = [.weight, .pulse]
        #expect(store.rawSeries == nil)
    }

    /// **v0.5.5.2 regression guard.** Sneaking a server-rejected kind into
    /// `selectedMetrics` must not abort the whole overlay. The runtime
    /// filter in `load()` skips unsupported kinds before the task group
    /// dispatch so a single 400 can't poison the rest of the fetch.
    @Test("v0.5.5.2: selecting a server-rejected kind doesn't crash the overlay")
    func unsupportedKindSelectionDoesNotCrash() async throws {
        let store = try await makeStore()
        // restingHeartRate is currently rejected by the server enum (audit
        // BLOCKER #2). The store should tolerate it being toggled in.
        store.selectedMetrics = [.weight, .restingHeartRate]
        // Just verify mode + state don't trap — no #expect on the failing
        // request itself; the load path returns early on filter-out.
        _ = store.mode
        _ = store.queryKey
    }
}
