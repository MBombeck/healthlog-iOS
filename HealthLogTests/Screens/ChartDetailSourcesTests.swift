import Foundation
@testable import HealthLog
import Testing

private typealias Measurement = HealthLog.Measurement

/// Pin the iOS-side per-source counting introduced in v0.4.1 to fix the
/// "Datenquellen wird ueberhaupt nicht gezeigt" user complaint. The pure
/// helper (`ChartDetailStore.computeSourceCounts`) bucketizes by source +
/// filters to the active range — both behaviours have edge cases worth
/// freezing.
@Suite("ChartDetailStore.computeSourceCounts — source-aware bucketing")
struct ChartDetailSourcesTests {
    private func measurement(daysAgo: Int, source: MeasurementSource) -> Measurement {
        let date = Date.now.addingTimeInterval(-Double(daysAgo) * 86400)
        return Measurement(
            id: "m-\(source.rawValue)-\(daysAgo)",
            kind: .weight,
            recordedAt: date,
            value: .scalar(80),
            note: nil,
            source: source
        )
    }

    @Test("Mixed-source range produces descending count breakdown")
    func mixedSourceBreakdown() {
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        // 3 Apple Health, 2 Withings, 1 Manual within range; 1 Manual out of range.
        let items: [Measurement] = [
            measurement(daysAgo: 0, source: .appleHealth),
            measurement(daysAgo: 5, source: .appleHealth),
            measurement(daysAgo: 10, source: .appleHealth),
            measurement(daysAgo: 4, source: .withings),
            measurement(daysAgo: 6, source: .withings),
            measurement(daysAgo: 2, source: .manual),
            measurement(daysAgo: 90, source: .manual) // out of range
        ]
        let counts = ChartDetailStore.computeSourceCounts(measurements: items, since: cutoff)
        #expect(counts.count == 3)
        #expect(counts[0].source == .appleHealth)
        #expect(counts[0].count == 3)
        #expect(counts[1].source == .withings)
        #expect(counts[1].count == 2)
        #expect(counts[2].source == .manual)
        #expect(counts[2].count == 1)
    }

    @Test("Out-of-range measurements are filtered before counting")
    func filtersOutOfRange() {
        let cutoff = Date.now.addingTimeInterval(-7 * 86400)
        let items: [Measurement] = [
            measurement(daysAgo: 1, source: .appleHealth),
            measurement(daysAgo: 8, source: .appleHealth) // out of 7d range
        ]
        let counts = ChartDetailStore.computeSourceCounts(measurements: items, since: cutoff)
        #expect(counts.count == 1)
        #expect(counts[0].count == 1)
    }

    @Test("Equal counts sort by source rawValue (stable order)")
    func equalCountsSortStable() {
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        let items: [Measurement] = [
            measurement(daysAgo: 1, source: .manual),
            measurement(daysAgo: 2, source: .withings)
        ]
        let counts = ChartDetailStore.computeSourceCounts(measurements: items, since: cutoff)
        // Both at count 1 — alphabetical by rawValue: manual < withings.
        #expect(counts[0].source == .manual)
        #expect(counts[1].source == .withings)
    }

    @Test("`latest` tracks the most recent reading per source")
    func latestTimestamp() {
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        let recentAH = measurement(daysAgo: 0, source: .appleHealth)
        let olderAH = measurement(daysAgo: 5, source: .appleHealth)
        let counts = ChartDetailStore.computeSourceCounts(measurements: [olderAH, recentAH], since: cutoff)
        #expect(counts.first?.latest == recentAH.recordedAt)
    }
}

/// Log-domain clamp pin — the log-scale toggle is undefined for non-positive
/// values; MetricChartMath.logDomain must always return a valid positive
/// range so the chart never trips an internal assertion when the user toggles.
@Suite("MetricChartMath.logDomain — log-scale safety clamp")
struct LogDomainTests {
    @Test("Positive-only series widens by ±5% padding")
    func paddedPositiveRange() {
        let points = [
            SeriesPoint(id: "a", at: .distantPast, value: 100, secondary: nil),
            SeriesPoint(id: "b", at: .distantPast, value: 200, secondary: nil)
        ]
        let d = MetricChartMath.logDomain(for: points)
        #expect(d.lowerBound < 100)
        #expect(d.upperBound > 200)
        #expect(d.lowerBound > 0)
    }

    @Test("All-zero series falls back to safe positive stub")
    func zeroSeriesStub() {
        let points = [SeriesPoint(id: "a", at: .distantPast, value: 0, secondary: nil)]
        let d = MetricChartMath.logDomain(for: points)
        #expect(d.lowerBound > 0)
        #expect(d.upperBound > d.lowerBound)
    }

    @Test("Empty series falls back to safe positive stub")
    func emptySeriesStub() {
        let d = MetricChartMath.logDomain(for: [])
        #expect(d.lowerBound > 0)
        #expect(d.upperBound > d.lowerBound)
    }

    @Test("BP secondary value is folded into the domain")
    func bpDomainIncludesDiastolic() {
        let points = [
            SeriesPoint(id: "a", at: .distantPast, value: 120, secondary: 60)
        ]
        let d = MetricChartMath.logDomain(for: points)
        // Diastolic 60 must contribute to the lower bound.
        #expect(d.lowerBound < 60)
    }
}

/// Pin the useLogScale state machine — this is just a Bool toggle today,
/// but a regression that resets it on range change would be subtle and
/// hard to spot. The store change should not bump queryKey.
@MainActor
@Suite("ChartDetailStore.useLogScale — state machine")
struct LogScaleStateTests {
    private func makeStore() async throws -> ChartDetailStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let insights = MetricInsightsRepository(api: api)
        return ChartDetailStore(kind: .weight, measurementsRepo: repo, insightsRepo: insights)
    }

    @Test("useLogScale defaults to false")
    func defaultLinear() async throws {
        let store = try await makeStore()
        #expect(store.useLogScale == false)
    }

    @Test("Toggling useLogScale does not bump queryKey (UI-only state)")
    func logScaleDoesNotRefetch() async throws {
        let store = try await makeStore()
        let initialKey = store.queryKey
        store.useLogScale = true
        #expect(store.queryKey == initialKey, "queryKey must remain stable — log toggle is render-only")
    }

    @Test("Range change DOES bump queryKey")
    func rangeChangeRefetches() async throws {
        let store = try await makeStore()
        let initialKey = store.queryKey
        store.range = .year
        #expect(store.queryKey != initialKey, "queryKey must move when range changes")
    }
}
